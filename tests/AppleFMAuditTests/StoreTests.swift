import Testing
import Foundation
@testable import AppleFMAuditCore

@Suite("StoreTests")
struct StoreTests {
    @Test("Store can insert, query, filter, and clear calls")
    func testStoreLifecycle() async throws {
        let store = try Store(path: ":memory:")

        let id1 = try await store.insert(
            method: "POST",
            path: "/v1/chat/completions",
            query: "",
            status: 200,
            durationMs: 45,
            reqHeaders: "{\"content-type\":\"application/json\"}",
            reqBody: "{\"model\":\"system\"}",
            resHeaders: "{\"content-type\":\"application/json\"}",
            resBody: "{\"usage\":{\"total_tokens\":10}}",
            error: nil
        )

        let id2 = try await store.insert(
            method: "GET",
            path: "/_audit/status",
            query: "",
            status: 200,
            durationMs: 2,
            reqHeaders: "{}",
            reqBody: "",
            resHeaders: "{}",
            resBody: "{}",
            error: nil
        )

        #expect(id1 > 0)
        #expect(id2 > id1)

        let all = try await store.listCalls()
        #expect(all.count == 2)
        #expect(all[0].id == id2)
        #expect(all[1].id == id1)
        #expect(all[1].totalTokens == 10)

        let filtered = try await store.listCalls(pathContains: "completions")
        #expect(filtered.count == 1)
        #expect(filtered[0].id == id1)

        let detail = try await store.getCall(id: id1)
        #expect(detail != nil)
        #expect(detail?.path == "/v1/chat/completions")
        #expect(detail?.totalTokens == 10)
        #expect(detail?.issue == "ok")

        try await store.clear()
        let empty = try await store.listCalls()
        #expect(empty.isEmpty)
    }
}
