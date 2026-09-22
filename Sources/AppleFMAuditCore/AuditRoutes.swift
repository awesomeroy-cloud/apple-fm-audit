import Foundation
import AsyncHTTPClient
import Hummingbird
import HTTPTypes
import NIOCore

public struct AuditRoutes: Sendable {
    public let store: Store
    public let client: HTTPClient
    public let listenHost: String
    public let listenPort: Int
    public let upstreamHost: String
    public let upstreamPort: Int
    public let dbPath: String
    public let staticDir: String
    public let fmBin: String?
    public let ttsService: TTSService

    public init(
        store: Store,
        client: HTTPClient,
        listenHost: String,
        listenPort: Int,
        upstreamHost: String,
        upstreamPort: Int,
        dbPath: String,
        staticDir: String,
        fmBin: String? = nil,
        ttsService: TTSService = TTSService()
    ) {
        self.store = store
        self.client = client
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
        self.dbPath = dbPath
        self.staticDir = staticDir
        self.fmBin = fmBin
        self.ttsService = ttsService
    }

    private func serveFile(filename: String, contentType: String) -> Response {
        let path = URL(fileURLWithPath: staticDir).appendingPathComponent(filename).path
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            let err = "{\"error\":\"missing static file\"}"
            return Response(
                status: .notFound,
                headers: [.contentType: "application/json", .cacheControl: "no-store"],
                body: .init(byteBuffer: ByteBuffer(string: err))
            )
        }
        var headers = HTTPFields()
        if let ctype = HTTPField.Name("content-type") {
            headers[ctype] = contentType
        }
        headers[.contentLength] = String(data.count)
        headers[.cacheControl] = "no-store"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(data: data)))
    }

    private func jsonResponse(status: HTTPResponse.Status = .ok, object: Any) -> Response {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else {
            return Response(status: .internalServerError, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(string: "{\"error\":\"json encoding error\"}")))
        }
        var headers = HTTPFields()
        headers[.contentType] = "application/json; charset=utf-8"
        headers[.contentLength] = String(data.count)
        headers[.cacheControl] = "no-store"
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(data: data)))
    }

    public func index(request: Request, context: some RequestContext) async throws -> Response {
        serveFile(filename: "index.html", contentType: "text/html; charset=utf-8")
    }

    public func css(request: Request, context: some RequestContext) async throws -> Response {
        serveFile(filename: "app.css", contentType: "text/css; charset=utf-8")
    }

    public func js(request: Request, context: some RequestContext) async throws -> Response {
        serveFile(filename: "app.js", contentType: "text/javascript; charset=utf-8")
    }

    public func favicon(request: Request, context: some RequestContext) async throws -> Response {
        serveFile(filename: "favicon.svg", contentType: "image/svg+xml")
    }

    public func meta(request: Request, context: some RequestContext) async throws -> Response {
        let metaObj: [String: Any] = [
            "listen": "\(listenHost):\(listenPort)",
            "upstream": "\(upstreamHost):\(upstreamPort)",
            "db": dbPath
        ]
        return jsonResponse(object: metaObj)
    }

    public func license(request: Request, context: some RequestContext) async throws -> Response {
        let info = License.inspect(customFmBinary: fmBin)
        let licObj: [String: Any] = [
            "agreed": info.agreed,
            "fm": info.fm,
            "status": info.status,
            "text": info.text,
            "command": info.command
        ]
        return jsonResponse(object: licObj)
    }

    public func status(request: Request, context: some RequestContext) async throws -> Response {
        let lic = License.inspect(customFmBinary: fmBin)
        let model = await UpstreamHealth.inspect(client: client, host: upstreamHost, port: upstreamPort)
        let statusObj: [String: Any] = [
            "listen": "\(listenHost):\(listenPort)",
            "upstream": "\(upstreamHost):\(upstreamPort)",
            "license": [
                "agreed": lic.agreed,
                "status": lic.status,
                "text": lic.text,
                "command": lic.command
            ],
            "model": model
        ]
        return jsonResponse(object: statusObj)
    }

    public func quota(request: Request, context: some RequestContext) async throws -> Response {
        let health = await UpstreamHealth.inspect(client: client, host: upstreamHost, port: upstreamPort)
        var pccQuota: [String: Any] = [
            "limit_reached": false,
            "approaching_limit": false,
            "status": "normal"
        ]
        var pccAvailable = false
        var pccReason = ""

        if let models = health["models"] as? [[String: Any]] {
            for m in models {
                if (m["name"] as? String) == "pcc" {
                    pccAvailable = (m["available"] as? Bool) ?? false
                    pccReason = (m["reason"] as? String) ?? ""
                    if let q = m["quota"] as? [String: Any] {
                        let reached = (q["limit_reached"] as? Bool) ?? false
                        let approaching = (q["approaching_limit"] as? Bool) ?? false
                        pccQuota["limit_reached"] = reached
                        pccQuota["approaching_limit"] = approaching
                        if let resetsAt = q["resets_at"] ?? q["resetsAt"] {
                            pccQuota["resets_at"] = resetsAt
                        }
                        if reached {
                            pccQuota["status"] = "limit_reached"
                        } else if approaching {
                            pccQuota["status"] = "approaching_limit"
                        } else {
                            pccQuota["status"] = "normal"
                        }
                    }
                }
            }
        }

        let resp: [String: Any] = [
            "system": [
                "name": "system",
                "type": "on-device",
                "quota": "unlimited",
                "available": (health["available"] as? Bool) ?? false
            ],
            "pcc": [
                "name": "pcc",
                "type": "cloud",
                "available": pccAvailable,
                "reason": pccReason,
                "quota": pccQuota
            ],
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        return jsonResponse(object: resp)
    }

    public func listCalls(request: Request, context: some RequestContext) async throws -> Response {
        let needle: String?
        if let query = request.uri.query {
            let params = query.components(separatedBy: "&")
            var found: String? = nil
            for param in params {
                let pair = param.components(separatedBy: "=")
                if pair.count == 2, pair[0] == "q" {
                    found = pair[1].removingPercentEncoding ?? pair[1]
                    break
                }
            }
            needle = found
        } else {
            needle = nil
        }

        let summaries = try await store.listCalls(pathContains: needle)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(["calls": summaries])
        var headers = HTTPFields()
        headers[.contentType] = "application/json; charset=utf-8"
        headers[.contentLength] = String(data.count)
        headers[.cacheControl] = "no-store"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(data: data)))
    }

    public func getCall(request: Request, context: some RequestContext) async throws -> Response {
        guard let idParam = context.parameters.get("id"),
              let callId = Int64(idParam) else {
            return jsonResponse(status: .notFound, object: ["error": "not found"])
        }

        guard let call = try await store.getCall(id: callId) else {
            return jsonResponse(status: .notFound, object: ["error": "not found"])
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(call)
        var headers = HTTPFields()
        headers[.contentType] = "application/json; charset=utf-8"
        headers[.contentLength] = String(data.count)
        headers[.cacheControl] = "no-store"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(data: data)))
    }

    public func clearCalls(request: Request, context: some RequestContext) async throws -> Response {
        try await store.clear()
        return jsonResponse(object: ["ok": true])
    }

    public func speech(request: Request, context: some RequestContext) async throws -> Response {
        let startClock = ContinuousClock.now
        let maxBody = 1024 * 1024
        var bodyBuffer = try await request.body.collect(upTo: maxBody)
        let bodyData = bodyBuffer.readData(length: bodyBuffer.readableBytes)
        let reqBodyStr = bodyData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        guard let validData = bodyData,
              let ttsReq = try? JSONDecoder().decode(TTSRequest.self, from: validData) else {
            let durationMs = Int((ContinuousClock.now - startClock) / .milliseconds(1))
            let err = [
                "error": [
                    "message": "Invalid JSON body for speech request",
                    "type": "invalid_request_error"
                ]
            ]
            let errJson = (try? JSONSerialization.data(withJSONObject: err)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            _ = try? await store.insert(
                method: "POST",
                path: "/v1/audio/speech",
                query: "",
                status: 400,
                durationMs: durationMs,
                reqHeaders: "{}",
                reqBody: reqBodyStr,
                resHeaders: "{\"content-type\":\"application/json\"}",
                resBody: errJson,
                error: "Invalid JSON body for speech request"
            )
            return jsonResponse(status: .badRequest, object: err)
        }

        do {
            let ttsResult = try await ttsService.synthesize(request: ttsReq)
            let durationMs = Int((ContinuousClock.now - startClock) / .milliseconds(1))
            var headers = HTTPFields()
            if let ctype = HTTPField.Name("content-type") {
                headers[ctype] = ttsResult.contentType
            }
            headers[.contentLength] = String(ttsResult.data.count)
            headers[.cacheControl] = "no-store"

            _ = try? await store.insert(
                method: "POST",
                path: "/v1/audio/speech",
                query: "",
                status: 200,
                durationMs: durationMs,
                reqHeaders: "{}",
                reqBody: reqBodyStr,
                resHeaders: "{\"content-type\":\"\(ttsResult.contentType)\",\"content-length\":\"\(ttsResult.data.count)\"}",
                resBody: "<\(ttsResult.contentType): \(ttsResult.data.count) bytes>",
                error: nil
            )

            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(data: ttsResult.data)))
        } catch {
            let durationMs = Int((ContinuousClock.now - startClock) / .milliseconds(1))
            let err = [
                "error": [
                    "message": error.localizedDescription,
                    "type": "invalid_request_error"
                ]
            ]
            let errJson = (try? JSONSerialization.data(withJSONObject: err)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            _ = try? await store.insert(
                method: "POST",
                path: "/v1/audio/speech",
                query: "",
                status: 400,
                durationMs: durationMs,
                reqHeaders: "{}",
                reqBody: reqBodyStr,
                resHeaders: "{\"content-type\":\"application/json\"}",
                resBody: errJson,
                error: error.localizedDescription
            )
            return jsonResponse(status: .badRequest, object: err)
        }
    }
}
