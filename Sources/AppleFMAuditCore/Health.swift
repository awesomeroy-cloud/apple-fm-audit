import Foundation
import AsyncHTTPClient
import NIOCore

public struct UpstreamHealth: Sendable {
    public static func parseHealth(raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [
                "reachable": false,
                "available": false,
                "name": "",
                "reason": "health is not JSON",
                "models": []
            ]
        }
        guard let models = payload["models"] as? [[String: Any]], !models.isEmpty else {
            return [
                "reachable": true,
                "available": false,
                "name": "",
                "reason": "no models in /health",
                "models": []
            ]
        }
        let first = models[0]
        let available = (first["available"] as? Bool) ?? false
        var reason = (first["reason"] as? String) ?? ""
        if !available && reason.isEmpty {
            reason = "system model unavailable"
        }
        return [
            "reachable": true,
            "available": available,
            "name": (first["name"] as? String) ?? "",
            "reason": available ? "" : reason,
            "models": models
        ]
    }

    public static func inspect(client: HTTPClient, host: String, port: Int) async -> [String: Any] {
        var parsed: [String: Any]
        do {
            var req = HTTPClientRequest(url: "http://\(host):\(port)/health")
            req.method = .GET
            let res = try await client.execute(req, timeout: .milliseconds(1500))
            let buf = try await res.body.collect(upTo: 1024 * 1024)
            let raw = String(buffer: buf)
            parsed = parseHealth(raw: raw)
            if res.status.code >= 400 && (parsed["available"] as? Bool) == true {
                parsed["available"] = false
                let r = (parsed["reason"] as? String) ?? ""
                parsed["reason"] = r.isEmpty ? "health HTTP \(res.status.code)" : r
            }
        } catch {
            parsed = [
                "reachable": false,
                "available": false,
                "name": "",
                "reason": error.localizedDescription,
                "models": []
            ]
        }

        let pcc = PCC.pccAvailability(health: parsed)
        parsed["pcc"] = [
            "state": pcc.state,
            "reason": pcc.reason
        ]
        return parsed
    }
}
