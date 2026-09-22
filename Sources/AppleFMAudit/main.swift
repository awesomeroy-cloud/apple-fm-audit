import Foundation
import AppleFMAuditCore
import AsyncHTTPClient
import Hummingbird

@main
struct EntryPoint {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment

        let listenHost = env["AFM_LISTEN_HOST"] ?? "127.0.0.1"
        let listenPort = Int(env["AFM_LISTEN_PORT"] ?? "1977") ?? 1977

        let upstreamRaw = env["AFM_UPSTREAM"] ?? "127.0.0.1:1976"
        let (upstreamHost, upstreamPort): (String, Int) = {
            if upstreamRaw.contains(":") {
                let parts = upstreamRaw.split(separator: ":")
                return (String(parts[0]), Int(parts[1]) ?? 1976)
            }
            return (upstreamRaw, 1976)
        }()

        let rootDir = FileManager.default.currentDirectoryPath
        let defaultDb = URL(fileURLWithPath: rootDir).appendingPathComponent("data/audit.sqlite").path
        let dbPath = env["AFM_DB"] ?? defaultDb

        let dbDir = URL(fileURLWithPath: dbPath).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: dbDir, withIntermediateDirectories: true)

        let defaultStatic = URL(fileURLWithPath: rootDir).appendingPathComponent("static").path
        let staticDir = env["AFM_STATIC_DIR"] ?? defaultStatic

        let store = try Store(path: dbPath)
        let client = HTTPClient(eventLoopGroupProvider: .singleton)

        let gate = License.inspect(customFmBinary: env["AFM_FM_BIN"])
        print("""
        apple-fm-audit
          ui       http://\(listenHost):\(listenPort)
          upstream http://\(upstreamHost):\(upstreamPort)
          sqlite   \(dbPath)
          fm       \(gate.status.isEmpty ? gate.fm : gate.status)
          clients  point OpenAI base URL at this origin
        """)

        if !gate.agreed {
            print("""

            Apple Foundation Models CLI terms are not agreed on this Mac.
            This process will not type yes for you.
              \(gate.command)
            Read the notice, type yes, then run: fm serve

            """)
            if !gate.text.isEmpty {
                print(gate.text)
                print("")
            }
        }

        let config = AppConfiguration(
            listenHost: listenHost,
            listenPort: listenPort,
            upstreamHost: upstreamHost,
            upstreamPort: upstreamPort,
            dbPath: dbPath,
            staticDir: staticDir,
            fmBin: env["AFM_FM_BIN"]
        )

        let app = AppBuilder.buildApplication(config: config, store: store, client: client)

        defer {
            Task {
                try? await client.shutdown()
                await store.close()
            }
        }

        try await app.runService()
    }
}
