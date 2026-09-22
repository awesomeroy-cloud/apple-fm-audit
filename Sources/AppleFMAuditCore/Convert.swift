import Foundation

public struct ResponsesSSEState: Sendable {
    public var started: Bool = false
    public var id: String = "resp_local"
    public var itemId: String = "msg_local"
    public var model: String = "system"
    public var text: String = ""
    public var seq: Int = 0
    public var completed: Bool = false
    public var createdAt: Int = Int(Date().timeIntervalSince1970)

    public init() {}
}

public enum Convert {
    private static let keepKeys: Set<String> = [
        "model", "messages", "stream", "temperature",
        "max_tokens", "max_completion_tokens", "response_format",
        "tools", "tool_choice", "stream_options", "n", "user",
        "reasoning_effort",
    ]

    public static func isResponsesPath(_ path: String) -> Bool {
        let clean = path.components(separatedBy: "?").first ?? path
        return clean == "/responses" || clean == "/v1/responses"
    }

    public static func rewriteUpstream(path: String, body: Data) -> (path: String, body: Data, isResponses: Bool) {
        guard isResponsesPath(path) else {
            return (path, body, false)
        }
        guard !body.isEmpty, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return ("/v1/chat/completions", body, true)
        }
        let chatReq = toChatRequest(payload: json)
        let outData = (try? JSONSerialization.data(withJSONObject: chatReq, options: [.fragmentsAllowed])) ?? body
        return ("/v1/chat/completions", outData, true)
    }

    public static func toChatRequest(payload: [String: Any]) -> [String: Any] {
        var messages: [[String: Any]] = []

        if let instructions = payload["instructions"] as? String, !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }

        if let inputMessages = payload["messages"] as? [Any] {
            for item in inputMessages {
                if let dict = item as? [String: Any] {
                    let role = normalizeRole(dict["role"])
                    let content = flattenContent(dict["content"])
                    messages.append(["role": role, "content": content])
                } else if let str = item as? String {
                    messages.append(["role": "user", "content": str])
                }
            }
        } else if let inputList = payload["input"] as? [Any] {
            for item in inputList {
                if let dict = item as? [String: Any] {
                    let role = normalizeRole(dict["role"])
                    let content = flattenContent(dict["content"])
                    messages.append(["role": role, "content": content])
                } else if let str = item as? String {
                    messages.append(["role": "user", "content": str])
                }
            }
        }

        var out: [String: Any] = [:]
        for (k, v) in payload where keepKeys.contains(k) {
            out[k] = v
        }

        if messages.isEmpty {
            messages.append(["role": "user", "content": ""])
        }
        out["messages"] = messages
        if out["model"] == nil {
            out["model"] = "system"
        }

        if let maxOut = payload["max_output_tokens"], out["max_tokens"] == nil {
            out["max_tokens"] = maxOut
        }

        if let reasoningObj = payload["reasoning"] as? [String: Any],
           let effort = reasoningObj["effort"] as? String,
           out["reasoning_effort"] == nil {
            out["reasoning_effort"] = effort
        }

        if let streamVal = out["stream"] {
            if let boolVal = streamVal as? Bool {
                out["stream"] = boolVal
            } else {
                let strVal = String(describing: streamVal).lowercased()
                out["stream"] = (strVal == "1" || strVal == "true" || strVal == "yes")
            }
        } else {
            out["stream"] = false
        }

        return out
    }

    public static func normalizeRole(_ role: Any?) -> String {
        guard let r = role as? String else { return "user" }
        switch r {
        case "developer", "system": return "system"
        case "assistant": return "assistant"
        case "tool", "function": return "tool"
        default: return "user"
        }
    }

    public static func flattenContent(_ content: Any?) -> Any {
        guard let content = content else { return "" }
        if let str = content as? String { return str }
        if let list = content as? [Any] {
            var texts: [String] = []
            var images: [[String: Any]] = []
            for part in list {
                if let s = part as? String {
                    texts.append(s)
                } else if let d = part as? [String: Any] {
                    let kind = d["type"] as? String
                    if kind == nil || kind == "text" || kind == "input_text" || kind == "output_text" {
                        texts.append(d["text"] as? String ?? "")
                    } else if kind == "image_url" || kind == "input_image" {
                        if let urlStr = d["image_url"] as? String {
                            images.append(["type": "image_url", "image_url": ["url": urlStr]])
                        } else if let urlDict = d["image_url"] as? [String: Any] {
                            images.append(["type": "image_url", "image_url": urlDict])
                        }
                    }
                }
            }
            if !images.isEmpty {
                var res: [[String: Any]] = []
                if !texts.isEmpty {
                    res.append(["type": "text", "text": texts.joined(separator: "\n")])
                }
                res.append(contentsOf: images)
                return res
            }
            return texts.joined(separator: "\n")
        }
        return String(describing: content)
    }

    public static func chatToResponse(chat: [String: Any]) -> [String: Any] {
        let choices = (chat["choices"] as? [[String: Any]]) ?? []
        let msg = choices.first?["message"] as? [String: Any] ?? [:]
        let text = msg["content"] as? String ?? ""
        let cid = String(describing: chat["id"] ?? "chatcmpl-local")
        let rid = cid.replacingOccurrences(of: "chatcmpl-", with: "resp_")
        let mid = cid.replacingOccurrences(of: "chatcmpl-", with: "msg_")
        let model = (chat["model"] as? String) ?? "system"
        let created = (chat["created"] as? Int) ?? Int(Date().timeIntervalSince1970)

        let outputMessage: [String: Any] = [
            "id": mid,
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [
                ["type": "output_text", "text": text, "annotations": []]
            ]
        ]

        var res: [String: Any] = [
            "id": rid,
            "object": "response",
            "created_at": created,
            "status": "completed",
            "model": model,
            "output": [outputMessage],
            "parallel_tool_calls": true,
            "temperature": 1.0,
            "tool_choice": "auto",
            "tools": [],
            "top_p": 1.0,
            "truncation": "disabled",
            "metadata": [:]
        ]
        if let usage = chat["usage"] as? [String: Any] {
            res["usage"] = [
                "input_tokens": usage["prompt_tokens"] ?? 0,
                "output_tokens": usage["completion_tokens"] ?? 0,
                "total_tokens": usage["total_tokens"] ?? 0
            ]
        }
        return res
    }

    private static func serializeJSON(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    public static func chatSSELineToResponseFrames(line: String, state: inout ResponsesSSEState) -> [String] {
        let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix("data:") else { return [] }
        let payload = String(raw.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" {
            state.completed = true
            var frames: [String] = []

            state.seq += 1
            let completedItem: [String: Any] = [
                "id": state.itemId,
                "type": "message",
                "role": "assistant",
                "status": "completed",
                "content": [
                    [
                        "type": "output_text",
                        "text": state.text,
                        "annotations": []
                    ]
                ]
            ]
            let itemJson = serializeJSON(completedItem)
            frames.append("event: response.output_item.done\ndata: {\"type\":\"response.output_item.done\",\"sequence_number\":\(state.seq),\"output_index\":0,\"item\":\(itemJson)}\n\n")

            state.seq += 1
            let completedResp: [String: Any] = [
                "id": state.id,
                "object": "response",
                "created_at": state.createdAt,
                "status": "completed",
                "model": state.model,
                "output": [completedItem],
                "usage": [
                    "input_tokens": 0,
                    "output_tokens": 0,
                    "total_tokens": 0
                ]
            ]
            let respJson = serializeJSON(completedResp)
            frames.append("event: response.completed\ndata: {\"type\":\"response.completed\",\"sequence_number\":\(state.seq),\"response\":\(respJson)}\n\n")
            return frames
        }

        guard let data = payload.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }

        if let cid = obj["id"] as? String {
            state.id = cid.replacingOccurrences(of: "chatcmpl-", with: "resp_")
            state.itemId = cid.replacingOccurrences(of: "chatcmpl-", with: "msg_")
        }
        if let m = obj["model"] as? String {
            state.model = m
        }
        if let created = obj["created"] as? Int {
            state.createdAt = created
        }

        var frames: [String] = []

        if !state.started {
            state.started = true
            state.seq += 1
            let initialResp: [String: Any] = [
                "id": state.id,
                "object": "response",
                "created_at": state.createdAt,
                "status": "in_progress",
                "model": state.model,
                "output": []
            ]
            let respJson = serializeJSON(initialResp)
            frames.append("event: response.created\ndata: {\"type\":\"response.created\",\"sequence_number\":\(state.seq),\"response\":\(respJson)}\n\n")

            state.seq += 1
            let initialItem: [String: Any] = [
                "id": state.itemId,
                "type": "message",
                "role": "assistant",
                "status": "in_progress",
                "content": []
            ]
            let itemJson = serializeJSON(initialItem)
            frames.append("event: response.output_item.added\ndata: {\"type\":\"response.output_item.added\",\"sequence_number\":\(state.seq),\"output_index\":0,\"item\":\(itemJson)}\n\n")
        }

        let choices = (obj["choices"] as? [[String: Any]]) ?? []
        if let delta = choices.first?["delta"] as? [String: Any],
           let piece = delta["content"] as? String, !piece.isEmpty {
            state.text += piece
            state.seq += 1
            let deltaEvent: [String: Any] = [
                "type": "response.output_text.delta",
                "sequence_number": state.seq,
                "item_id": state.itemId,
                "output_index": 0,
                "content_index": 0,
                "delta": piece
            ]
            let deltaJson = serializeJSON(deltaEvent)
            frames.append("event: response.output_text.delta\ndata: \(deltaJson)\n\n")
        }

        return frames
    }
}
