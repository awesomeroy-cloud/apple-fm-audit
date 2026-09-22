import Foundation
import AsyncHTTPClient
import Hummingbird
import HTTPTypes
import NIOCore
import NIOHTTP1

public struct ProxyHandler: Sendable {
    public let client: HTTPClient
    public let upstreamHost: String
    public let upstreamPort: Int
    public let store: Store

    public init(
        client: HTTPClient,
        upstreamHost: String,
        upstreamPort: Int,
        store: Store
    ) {
        self.client = client
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
        self.store = store
    }

    public func handle(request: Request, context: some RequestContext) async throws -> Response {
        let maxBody = 8 * 1024 * 1024
        let reqLength = request.headers[.contentLength].flatMap { Int($0) } ?? 0
        if reqLength > maxBody {
            let errJson = "{\"error\":\"request body too large\"}"
            return Response(
                status: .contentTooLarge,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(string: errJson))
            )
        }

        var reqBodyBuffer = try await request.body.collect(upTo: maxBody)
        let reqBodyData = reqBodyBuffer.readData(length: reqBodyBuffer.readableBytes) ?? Data()

        let rawPath = request.uri.path
        let query = request.uri.query ?? ""
        var (fwdPath, fwdBody, asResponses) = Convert.rewriteUpstream(path: rawPath, body: reqBodyData)

        let wantModel = PCC.requestedModel(body: fwdBody)
        var usedModel = wantModel ?? "system"
        var fallbackNote: String? = nil

        let isMutation = request.method == .post || request.method == .put || request.method == .patch
        if isMutation && PCC.isPCCModel(wantModel) {
            let health = await UpstreamHealth.inspect(client: client, host: upstreamHost, port: upstreamPort)
            let chosen = PCC.chooseModel(requested: wantModel, health: health)
            usedModel = chosen.model
            fallbackNote = chosen.fallback
            if !fwdBody.isEmpty && usedModel != "pcc" {
                fwdBody = PCC.setJSONModel(body: fwdBody, model: usedModel)
            }
        }

        var upstreamHeaders = Headers.toUpstreamHeaders(request.headers)
        if !fwdBody.isEmpty {
            upstreamHeaders.replaceOrAdd(name: "Content-Type", value: "application/json")
            upstreamHeaders.replaceOrAdd(name: "Content-Length", value: String(fwdBody.count))
        } else {
            upstreamHeaders.remove(name: "Content-Length")
        }

        let queryString = query.isEmpty ? "" : "?\(query)"
        let upstreamURL = "http://\(upstreamHost):\(upstreamPort)\(fwdPath)\(queryString)"

        var fwdReq = HTTPClientRequest(url: upstreamURL)
        fwdReq.method = HTTPMethod(rawValue: request.method.rawValue)
        fwdReq.headers = upstreamHeaders
        if !fwdBody.isEmpty {
            fwdReq.body = .bytes(ByteBuffer(data: fwdBody))
        }

        let startClock = ContinuousClock.now
        var errorNote: String? = fallbackNote

        var resp: HTTPClientResponse
        do {
            resp = try await client.execute(fwdReq, timeout: .seconds(600))
        } catch {
            let durationMs = Int((ContinuousClock.now - startClock) / .milliseconds(1))
            let errMsg = "upstream \(upstreamHost):\(upstreamPort): \(error.localizedDescription)"
            let errBody = "{\"error\":{\"message\":\"\(errMsg)\",\"type\":\"proxy_error\"}}"
            await storeCall(
                request: request,
                query: query,
                reqBody: reqBodyData,
                status: 502,
                durationMs: durationMs,
                resHeaders: ["Content-Type": "application/json"],
                resBody: Data(errBody.utf8),
                error: errMsg
            )
            return Response(
                status: .badGateway,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(string: errBody))
            )
        }

        var peekBuffer: ByteBuffer? = nil
        let ctypeEarly = resp.headers.first(name: "content-type")?.lowercased() ?? ""
        let streamingEarly = ctypeEarly.contains("text/event-stream")

        if PCC.isPCCModel(wantModel) && usedModel == "pcc" && !streamingEarly {
            let peek = try await resp.body.collect(upTo: maxBody)
            let peekStr = String(buffer: peek)
            if PCC.isNetworkFailure(status: Int(resp.status.code), resBody: peekStr, error: nil) {
                usedModel = "system"
                fallbackNote = "pcc network failure, retry on-device"
                errorNote = fallbackNote
                fwdBody = PCC.setJSONModel(body: fwdBody, model: "system")
                upstreamHeaders.replaceOrAdd(name: "Content-Length", value: String(fwdBody.count))
                fwdReq.headers = upstreamHeaders
                fwdReq.body = .bytes(ByteBuffer(data: fwdBody))

                do {
                    resp = try await client.execute(fwdReq, timeout: .seconds(600))
                    peekBuffer = nil
                } catch {
                    let durationMs = Int((ContinuousClock.now - startClock) / .milliseconds(1))
                    let errMsg = "upstream retry \(upstreamHost):\(upstreamPort): \(error.localizedDescription)"
                    let errBody = "{\"error\":{\"message\":\"\(errMsg)\",\"type\":\"proxy_error\"}}"
                    await storeCall(
                        request: request,
                        query: query,
                        reqBody: reqBodyData,
                        status: 502,
                        durationMs: durationMs,
                        resHeaders: ["Content-Type": "application/json"],
                        resBody: Data(errBody.utf8),
                        error: errMsg
                    )
                    return Response(
                        status: .badGateway,
                        headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(string: errBody))
                    )
                }
            } else {
                peekBuffer = peek
            }
        }

        let upstreamStatus = Int(resp.status.code)
        let isStreaming = resp.headers.first(name: "content-type")?.lowercased().contains("text/event-stream") == true

        var downstreamHeaders = Headers.toDownstreamFields(resp.headers, asResponses: asResponses, streaming: isStreaming)
        if let note = fallbackNote {
            if let mField = HTTPField.Name("x-apple-fm-model") {
                downstreamHeaders[mField] = usedModel
            }
            if let fField = HTTPField.Name("x-apple-fm-fallback") {
                downstreamHeaders[fField] = String(note.prefix(180))
            }
        }

        var finalResHeaders: [String: String] = [:]
        for field in downstreamHeaders {
            finalResHeaders[field.name.rawName] = field.value
        }

        let storeRef = self.store
        let reqMethod = request.method.rawValue
        let reqUriPath = request.uri.path
        let reqHeadersMap = Dictionary(uniqueKeysWithValues: request.headers.map { ($0.name.rawName, $0.value) })

        if isStreaming {
            if asResponses {
                downstreamHeaders[.contentType] = "text/event-stream; charset=utf-8"
            }
            downstreamHeaders[.cacheControl] = "no-cache"

            let captureRespBody = resp.body
            let captureAsResponses = asResponses
            let captureReqBodyData = reqBodyData
            let captureFinalResHeaders = finalResHeaders
            let captureInitialError = errorNote
            let captureUpstreamStatus = upstreamStatus

            let responseBody = ResponseBody(contentLength: nil) { writer in
                var accData = Data()
                var currentError = captureInitialError
                do {
                    if captureAsResponses {
                        var state = ResponsesSSEState()
                        var lineBuffer = ""
                        for try await chunk in captureRespBody {
                            let chunkStr = String(buffer: chunk)
                            lineBuffer += chunkStr
                            while let nl = lineBuffer.firstIndex(of: "\n") {
                                let line = String(lineBuffer[...nl])
                                lineBuffer.removeSubrange(...nl)
                                let frames = Convert.chatSSELineToResponseFrames(line: line, state: &state)
                                for frame in frames {
                                    let frameData = Data(frame.utf8)
                                    accData.append(frameData)
                                    try await writer.write(ByteBuffer(data: frameData))
                                }
                            }
                        }
                        if !lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let frames = Convert.chatSSELineToResponseFrames(line: lineBuffer + "\n", state: &state)
                            for frame in frames {
                                let frameData = Data(frame.utf8)
                                accData.append(frameData)
                                try await writer.write(ByteBuffer(data: frameData))
                            }
                        }
                        if !state.completed {
                            let frames = Convert.chatSSELineToResponseFrames(line: "data: [DONE]\n", state: &state)
                            for frame in frames {
                                let frameData = Data(frame.utf8)
                                accData.append(frameData)
                                try await writer.write(ByteBuffer(data: frameData))
                            }
                        }
                    } else {
                        for try await chunk in captureRespBody {
                            if let bytes = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) {
                                accData.append(bytes)
                            }
                            try await writer.write(chunk)
                        }
                    }
                    try await writer.finish(nil)
                } catch {
                    currentError = error.localizedDescription
                    throw error
                }

                let durationMs = Int((ContinuousClock.now - startClock) / .milliseconds(1))
                let reqJson = (try? JSONSerialization.data(withJSONObject: reqHeadersMap)) ?? Data()
                let resJson = (try? JSONSerialization.data(withJSONObject: captureFinalResHeaders)) ?? Data()
                _ = try? await storeRef.insert(
                    method: reqMethod,
                    path: reqUriPath,
                    query: query,
                    status: captureUpstreamStatus,
                    durationMs: durationMs,
                    reqHeaders: String(data: reqJson, encoding: .utf8) ?? "{}",
                    reqBody: String(data: captureReqBodyData, encoding: .utf8) ?? "",
                    resHeaders: String(data: resJson, encoding: .utf8) ?? "{}",
                    resBody: String(data: accData, encoding: .utf8) ?? "",
                    error: currentError
                )
            }

            return Response(
                status: HTTPResponse.Status(code: Int(resp.status.code)),
                headers: downstreamHeaders,
                body: responseBody
            )
        } else {
            var resBuffer: ByteBuffer
            if let peek = peekBuffer {
                resBuffer = peek
            } else {
                resBuffer = try await resp.body.collect(upTo: maxBody)
            }
            var resData = resBuffer.readData(length: resBuffer.readableBytes) ?? Data()

            if asResponses && resp.status == .ok {
                if let chat = (try? JSONSerialization.jsonObject(with: resData)) as? [String: Any],
                   (chat["object"] as? String) == "chat.completion" {
                    let translated = Convert.chatToResponse(chat: chat)
                    resData = (try? JSONSerialization.data(withJSONObject: translated, options: [.fragmentsAllowed])) ?? resData
                }
            }

            downstreamHeaders[.contentLength] = String(resData.count)
            finalResHeaders["content-length"] = String(resData.count)

            let durationMs = Int((ContinuousClock.now - startClock) / .milliseconds(1))
            let reqJson = (try? JSONSerialization.data(withJSONObject: reqHeadersMap)) ?? Data()
            let resJson = (try? JSONSerialization.data(withJSONObject: finalResHeaders)) ?? Data()
            _ = try? await storeRef.insert(
                method: reqMethod,
                path: reqUriPath,
                query: query,
                status: upstreamStatus,
                durationMs: durationMs,
                reqHeaders: String(data: reqJson, encoding: .utf8) ?? "{}",
                reqBody: String(data: reqBodyData, encoding: .utf8) ?? "",
                resHeaders: String(data: resJson, encoding: .utf8) ?? "{}",
                resBody: String(data: resData, encoding: .utf8) ?? "",
                error: errorNote
            )

            return Response(
                status: HTTPResponse.Status(code: Int(resp.status.code)),
                headers: downstreamHeaders,
                body: .init(byteBuffer: ByteBuffer(data: resData))
            )
        }
    }

    private func storeCall(
        request: Request,
        query: String,
        reqBody: Data,
        status: Int,
        durationMs: Int,
        resHeaders: [String: String],
        resBody: Data,
        error: String?
    ) async {
        let reqHeadersMap = Dictionary(uniqueKeysWithValues: request.headers.map { ($0.name.rawName, $0.value) })
        let reqJson = (try? JSONSerialization.data(withJSONObject: reqHeadersMap)) ?? Data()
        let resJson = (try? JSONSerialization.data(withJSONObject: resHeaders)) ?? Data()
        _ = try? await store.insert(
            method: request.method.rawValue,
            path: request.uri.path,
            query: query,
            status: status,
            durationMs: durationMs,
            reqHeaders: String(data: reqJson, encoding: .utf8) ?? "{}",
            reqBody: String(data: reqBody, encoding: .utf8) ?? "",
            resHeaders: String(data: resJson, encoding: .utf8) ?? "{}",
            resBody: String(data: resBody, encoding: .utf8) ?? "",
            error: error
        )
    }
}
