import Foundation
import Testing
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import AsyncHTTPClient
@testable import AppleFMAuditCore

@Suite("ProxyTests")
struct ProxyTests {
    @Test("Header filtering strips hop-by-hop and sec-fetch headers")
    func testHeaderFiltering() {
        var fields = HTTPFields()
        fields[.contentType] = "application/json"
        fields[.authorization] = "Bearer secret"
        fields[.origin] = "https://malicious.test"
        fields[HTTPField.Name("Referer")!] = "https://malicious.test/page"
        fields[HTTPField.Name("Sec-Fetch-Mode")!] = "cors"
        fields[HTTPField.Name("Sec-Fetch-Site")!] = "cross-site"

        let upstreamHeaders = Headers.toUpstreamHeaders(fields)
        let names = Set(upstreamHeaders.map { $0.name.lowercased() })

        #expect(!names.contains("origin"))
        #expect(!names.contains("referer"))
        #expect(!names.contains("sec-fetch-mode"))
        #expect(!names.contains("sec-fetch-site"))
        #expect(names.contains("content-type"))
        #expect(names.contains("authorization"))
    }

    @Test("Local paths classification")
    func testLocalPaths() {
        #expect(Headers.isLocalPath("/"))
        #expect(Headers.isLocalPath("/app.css"))
        #expect(Headers.isLocalPath("/app.js"))
        #expect(Headers.isLocalPath("/favicon.ico"))
        #expect(Headers.isLocalPath("/favicon.svg"))
        #expect(Headers.isLocalPath("/_audit/status"))
        #expect(Headers.isLocalPath("/_audit/calls?q=test"))
        #expect(Headers.isLocalPath("/v1/audio/speech"))

        #expect(!Headers.isLocalPath("/v1/chat/completions"))
        #expect(!Headers.isLocalPath("/v1/models"))
        #expect(!Headers.isLocalPath("/responses"))
        #expect(!Headers.isLocalPath("/health"))
    }

    @Test("Wildcard router test")
    func testWildcardRouter() async throws {
        let router = Router()
        router.post("/v1/audio/speech") { req, ctx in
            return "speech"
        }
        router.on("**", method: .post) { request, context in
            return "catchall"
        }
        router.on("v1/**", method: .post) { request, context in
            return "v1_catchall"
        }
        let app = Application(responder: router.buildResponder())
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/audio/speech", method: .post) { response in
                #expect(response.status == .ok)
            }
            try await client.execute(uri: "/v1/chat/completions", method: .post) { response in
                print("V1 CHAT STATUS:", response.status)
                #expect(response.status == .ok)
            }
            try await client.execute(uri: "/other/path", method: .post) { response in
                print("OTHER STATUS:", response.status)
                #expect(response.status == .ok)
            }
        }
    }
}

