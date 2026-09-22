import Foundation
import Testing
import Hummingbird
import HummingbirdTesting
import AsyncHTTPClient
@testable import AppleFMAuditCore

@Suite("AuditRoutesTests")
struct AuditRoutesTests {
    func makeTestApp() throws -> (Application<some HTTPResponder<BasicRequestContext>>, Store, HTTPClient, String) {
        let tempDir = NSTemporaryDirectory()
        let dbPath = URL(fileURLWithPath: tempDir).appendingPathComponent("test_audit_\(UUID().uuidString).sqlite").path
        let store = try Store(path: dbPath)
        let client = HTTPClient(eventLoopGroupProvider: .singleton)

        let rootDir = FileManager.default.currentDirectoryPath
        let staticDir = URL(fileURLWithPath: rootDir).appendingPathComponent("static").path

        let config = AppConfiguration(
            listenHost: "127.0.0.1",
            listenPort: 1977,
            upstreamHost: "127.0.0.1",
            upstreamPort: 1976,
            dbPath: dbPath,
            staticDir: staticDir
        )

        let router = AppBuilder.buildRouter(config: config, store: store, client: client)
        let app = Application(responder: router.buildResponder())
        return (app, store, client, dbPath)
    }

    @Test("Serves static files")
    func testStaticFiles() async throws {
        let (app, _, client, dbPath) = try makeTestApp()
        defer {
            try? FileManager.default.removeItem(atPath: dbPath)
        }
        defer {
            _ = Task {
                try? await client.shutdown()
            }
        }

        try await app.test(.router) { testClient in
            try await testClient.execute(uri: "/", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType]?.contains("text/html") == true)
            }

            try await testClient.execute(uri: "/app.css", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType]?.contains("text/css") == true)
            }

            try await testClient.execute(uri: "/app.js", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType]?.contains("javascript") == true)
            }
        }
    }

    @Test("Audit meta and license endpoints")
    func testMetaAndLicense() async throws {
        let (app, _, client, dbPath) = try makeTestApp()
        defer {
            try? FileManager.default.removeItem(atPath: dbPath)
        }
        defer {
            _ = Task {
                try? await client.shutdown()
            }
        }

        try await app.test(.router) { testClient in
            try await testClient.execute(uri: "/_audit/meta", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("listen"))
                #expect(body.contains("upstream"))
                #expect(body.contains("db"))
            }

            try await testClient.execute(uri: "/_audit/license", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("agreed"))
                #expect(body.contains("fm"))
            }

            try await testClient.execute(uri: "/_audit/quota", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("system"))
                #expect(body.contains("pcc"))
                #expect(body.contains("quota"))
            }
        }
    }

    @Test("Audit calls and store inspection")
    func testCallsEndpoints() async throws {
        let (app, store, client, dbPath) = try makeTestApp()
        defer {
            try? FileManager.default.removeItem(atPath: dbPath)
        }
        defer {
            _ = Task {
                try? await client.shutdown()
            }
        }

        _ = try await store.insert(
            method: "POST",
            path: "/v1/chat/completions",
            query: "",
            status: 200,
            durationMs: 45,
            reqHeaders: "{}",
            reqBody: "{\"model\":\"system\"}",
            resHeaders: "{}",
            resBody: "{\"usage\":{\"total_tokens\":10}}",
            error: nil
        )

        try await app.test(.router) { testClient in
            try await testClient.execute(uri: "/_audit/calls", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("/v1/chat/completions"))
                #expect(body.contains("\"status\":200"))
            }

            try await testClient.execute(uri: "/_audit/calls/1", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("/v1/chat/completions"))
            }

            try await testClient.execute(uri: "/_audit/calls", method: .delete) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("\"ok\":true"))
            }

            try await testClient.execute(uri: "/_audit/calls", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body == "{\"calls\":[]}")
            }
        }
    }

    @Test("Native TTS audio synthesis endpoint")
    func testTTSEndpoint() async throws {
        let (app, _, client, dbPath) = try makeTestApp()
        defer {
            try? FileManager.default.removeItem(atPath: dbPath)
        }
        defer {
            _ = Task {
                try? await client.shutdown()
            }
        }

        try await app.test(.router) { testClient in
            let body = ByteBuffer(string: "{\"input\":\"Testing Apple FM Audit TTS\",\"voice\":\"Samantha\"}")
            try await testClient.execute(uri: "/v1/audio/speech", method: .post, headers: [.contentType: "application/json"], body: body) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "audio/wav")
                #expect(response.body.readableBytes > 1000)
            }
        }
    }

    @Test("Chat completions route matches and proxies")
    func testChatCompletionsRoute() async throws {
        let (app, _, client, dbPath) = try makeTestApp()
        defer {
            try? FileManager.default.removeItem(atPath: dbPath)
        }
        defer {
            _ = Task {
                try? await client.shutdown()
            }
        }

        try await app.test(.router) { testClient in
            let body = ByteBuffer(string: "{\"model\":\"system\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}")
            try await testClient.execute(uri: "/v1/chat/completions", method: .post, headers: [.contentType: "application/json"], body: body) { response in
                print("STATUS WAS:", response.status)
                #expect(response.status != .notFound)
            }
        }
    }
}

