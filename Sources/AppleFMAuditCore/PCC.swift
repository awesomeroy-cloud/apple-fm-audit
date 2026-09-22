import Foundation

public enum PCC {
    public static let ids: Set<String> = [
        "pcc",
        "private-cloud-compute",
        "privatecloudcompute",
        "private_cloud_compute",
        "afm-pcc",
    ]

    public static let networkMarkers: [String] = [
        "networkfailure",
        "network connection",
        "not connected to the internet",
        "internet connection appears to be offline",
        "the network connection was lost",
        "nsurlerror",
        "timed out",
        "timeout",
        "connection reset",
        "no route to host",
        "offline",
    ]

    public static func isPCCModel(_ name: String?) -> Bool {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        let key = name.replacingOccurrences(of: "_", with: "-")
        return ids.contains(key) || key == "pcc"
    }

    public static func pccAvailability(health: [String: Any]) -> (state: String, reason: String) {
        let reachable = (health["reachable"] as? Bool) ?? false
        if !reachable {
            return ("unreachable", (health["reason"] as? String) ?? "upstream down")
        }
        let models = (health["models"] as? [[String: Any]]) ?? []
        guard let entry = models.first(where: { ($0["name"] as? String) == "pcc" }) else {
            return ("unsupported", "fm has no pcc; macOS 27.2 restored it")
        }
        if (entry["available"] as? Bool) == true {
            return ("available", "")
        }
        let raw = (entry["reason"] as? String) ?? ""
        let low = raw.lowercased().replacingOccurrences(of: " ", with: "")
        if low.contains("devicenoteligible") || raw.lowercased().contains("not eligible") {
            return ("deviceNotEligible", raw.isEmpty ? "deviceNotEligible" : raw)
        }
        if low.contains("systemnotready") || raw.lowercased().contains("not ready") {
            return ("systemNotReady", raw.isEmpty ? "systemNotReady" : raw)
        }
        return ("unavailable", raw.isEmpty ? "unavailable" : raw)
    }

    public static func chooseModel(requested: String?, health: [String: Any]) -> (model: String, fallback: String?) {
        let name = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "system"
        if !isPCCModel(name) {
            return (name.isEmpty ? "system" : name, nil)
        }
        let info = pccAvailability(health: health)
        if info.state == "available" {
            return ("pcc", nil)
        }
        return ("system", "pcc \(info.state): \(info.reason)")
    }

    public static func isNetworkFailure(status: Int?, resBody: String?, error: String?) -> Bool {
        let text = "\(resBody ?? "") \(error ?? "")".lowercased()
        if text.isEmpty || text.contains("unknown model") {
            return false
        }
        return networkMarkers.contains { text.contains($0) }
    }

    public static func requestedModel(body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return json["model"] as? String
    }

    public static func setJSONModel(body: Data, model: String) -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return body
        }
        json["model"] = model
        return (try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])) ?? body
    }
}
