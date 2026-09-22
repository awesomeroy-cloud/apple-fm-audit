import Foundation
import HTTPTypes
import NIOHTTP1

public enum Headers {
    public static let hopByHop: Set<String> = [
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailers",
        "transfer-encoding",
        "upgrade",
        "host",
        "origin",
        "referer",
    ]

    public static let localFiles: Set<String> = [
        "/",
        "/app.css",
        "/app.js",
        "/favicon.ico",
        "/favicon.svg",
    ]

    public static func isLocalPath(_ path: String) -> Bool {
        let clean = path.components(separatedBy: "?").first ?? path
        if localFiles.contains(clean) {
            return true
        }
        return clean.hasPrefix("/_audit/") || clean == "/v1/audio/speech"
    }

    public static func toUpstreamHeaders(_ fields: HTTPFields) -> HTTPHeaders {
        var headers = HTTPHeaders()
        for field in fields {
            let key = field.name.rawName
            let lk = key.lowercased()
            if hopByHop.contains(lk) || lk.hasPrefix("sec-fetch-") {
                continue
            }
            headers.add(name: key, value: field.value)
        }
        return headers
    }

    public static let downstreamHopByHop: Set<String> = [
        "connection",
        "keep-alive",
        "transfer-encoding",
        "content-length",
        "access-control-allow-origin",
        "access-control-allow-methods",
        "access-control-allow-headers",
        "access-control-max-age",
        "access-control-expose-headers",
    ]

    public static func toDownstreamFields(_ headers: HTTPHeaders, asResponses: Bool, streaming: Bool) -> HTTPFields {
        var fields = HTTPFields()
        for (name, value) in headers {
            let lk = name.lowercased()
            if downstreamHopByHop.contains(lk) {
                continue
            }
            if asResponses && streaming && lk == "content-type" {
                continue
            }
            if let fieldName = HTTPField.Name(name) {
                fields.append(HTTPField(name: fieldName, value: value))
            }
        }
        return fields
    }
}
