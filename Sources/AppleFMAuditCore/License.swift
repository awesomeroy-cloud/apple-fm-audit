import Foundation

public struct LicenseInfo: Sendable, Codable {
    public let agreed: Bool
    public let fm: String
    public let status: String
    public let text: String
    public let command: String

    public init(
        agreed: Bool,
        fm: String,
        status: String,
        text: String,
        command: String = "sudo fm license"
    ) {
        self.agreed = agreed
        self.fm = fm
        self.status = status
        self.text = text
        self.command = command
    }
}

public enum License {
    public static func resolveFmBinary(customPath: String? = nil) -> String {
        if let custom = customPath, !custom.isEmpty {
            return custom
        }
        if let env = ProcessInfo.processInfo.environment["AFM_FM_BIN"], !env.isEmpty {
            return env
        }
        let candidates = [
            "/usr/bin/fm",
            "/usr/local/bin/fm",
            "/opt/homebrew/bin/fm"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "fm"
    }

    public static func parseStatus(text: String, returnCode: Int32) -> Bool {
        let low = text.lowercased()
        if low.contains("have not agreed") || low.contains("not agreed") {
            return false
        }
        if returnCode != 0 {
            return false
        }
        return low.contains("agreed to license") || low.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("agreed")
    }

    public static func run(executable: String, arguments: [String], timeoutSeconds: Double = 15.0) -> (code: Int32, output: String) {
        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        if process.executableURL?.path != "/usr/bin/env" {
            process.arguments = arguments
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (127, "\(executable) not found: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return (124, "timed out")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, out)
    }

    public static func inspect(customFmBinary: String? = nil) -> LicenseInfo {
        let binary = resolveFmBinary(customPath: customFmBinary)
        let (statusRet, statusText) = run(executable: binary, arguments: ["license", "--status"])
        let agreed = parseStatus(text: statusText, returnCode: statusRet)
        var showText = ""
        if !agreed {
            let (_, sText) = run(executable: binary, arguments: ["license", "--show"])
            let trimmed = sText.trimmingCharacters(in: .whitespacesAndNewlines)
            showText = trimmed.isEmpty ? statusText.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
        }
        return LicenseInfo(
            agreed: agreed,
            fm: binary,
            status: statusText.trimmingCharacters(in: .whitespacesAndNewlines),
            text: showText,
            command: "sudo fm license"
        )
    }
}
