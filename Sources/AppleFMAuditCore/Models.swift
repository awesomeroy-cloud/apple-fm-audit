import Foundation

public struct CallRecord: Sendable, Codable {
    public let id: Int64
    public let ts: Double
    public let method: String
    public let path: String
    public let query: String
    public let status: Int?
    public let durationMs: Int?
    public let reqHeaders: String
    public let reqBody: String
    public let resHeaders: String
    public let resBody: String
    public let error: String?

    public init(
        id: Int64 = 0,
        ts: Double = Date().timeIntervalSince1970,
        method: String,
        path: String,
        query: String = "",
        status: Int?,
        durationMs: Int?,
        reqHeaders: String = "{}",
        reqBody: String = "",
        resHeaders: String = "{}",
        resBody: String = "",
        error: String? = nil
    ) {
        self.id = id
        self.ts = ts
        self.method = method
        self.path = path
        self.query = query
        self.status = status
        self.durationMs = durationMs
        self.reqHeaders = reqHeaders
        self.reqBody = reqBody
        self.resHeaders = resHeaders
        self.resBody = resBody
        self.error = error
    }
}

public struct CallSummary: Sendable, Codable {
    public let id: Int64
    public let ts: Double
    public let method: String
    public let path: String
    public let query: String
    public let status: Int?
    public let durationMs: Int?
    public let error: String?
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?
    public let issue: String
    public let issueLabel: String

    enum CodingKeys: String, CodingKey {
        case id, ts, method, path, query, status, error
        case durationMs = "duration_ms"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case issue
        case issueLabel = "issue_label"
    }
}

public struct CallDetail: Sendable, Codable {
    public let id: Int64
    public let ts: Double
    public let method: String
    public let path: String
    public let query: String
    public let status: Int?
    public let durationMs: Int?
    public let reqHeaders: String
    public let reqBody: String
    public let resHeaders: String
    public let resBody: String
    public let error: String?
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?
    public let issue: String
    public let issueLabel: String

    enum CodingKeys: String, CodingKey {
        case id, ts, method, path, query, status, error
        case durationMs = "duration_ms"
        case reqHeaders = "req_headers"
        case reqBody = "req_body"
        case resHeaders = "res_headers"
        case resBody = "res_body"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case issue
        case issueLabel = "issue_label"
    }
}

public enum Annotate {
    public static func classifyIssue(status: Int?, resBody: String?, error: String?) -> (id: String, label: String) {
        let text = "\(resBody ?? "") \(error ?? "")".lowercased()
        if text.contains("cross-site") || text.contains("csrf") {
            return ("csrf", "csrf")
        }
        if text.contains("guardrail") {
            return ("guardrail", "guardrail")
        }
        if text.contains("contextwindow") || text.contains("context window") || text.contains("prompt is too long") || text.contains("context size") {
            return ("context", "context")
        }
        if text.contains("assetsunavailable") || text.contains("assets unavailable") {
            return ("assets", "assets")
        }
        if let err = error, err.hasPrefix("pcc "), (status == nil || status! < 400) {
            return ("fallback", "fallback")
        }
        if text.contains("broken pipe") || text.contains("proxy_error") || text.contains("upstream") {
            return ("proxy", "proxy")
        }
        if let st = status, st >= 400 {
            if text.contains("invalid_request") || text.contains("unknown model") || st == 400 {
                return ("invalid", "invalid")
            }
            if st >= 500 {
                return ("server", "server")
            }
            return ("client", "client")
        }
        return ("ok", "ok")
    }

    public static func extractUsage(resBody: String?) -> (prompt: Int?, completion: Int?, total: Int?) {
        guard let body = resBody, !body.isEmpty, let data = body.data(using: .utf8) else {
            return (nil, nil, nil)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any] else {
            return (nil, nil, nil)
        }
        let prompt = (usage["prompt_tokens"] ?? usage["input_tokens"]) as? Int
        let completion = (usage["completion_tokens"] ?? usage["output_tokens"]) as? Int
        let total = usage["total_tokens"] as? Int
        return (prompt, completion, total)
    }
}
