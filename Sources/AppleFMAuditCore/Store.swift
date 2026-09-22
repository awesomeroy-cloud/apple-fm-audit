import Foundation
import SQLite3

final class DBHandle: @unchecked Sendable {
    var pointer: OpaquePointer?
    init(_ pointer: OpaquePointer?) {
        self.pointer = pointer
    }
    deinit {
        if let ptr = pointer {
            sqlite3_close(ptr)
        }
    }
}

public actor Store {
    private let dbHandle: DBHandle
    public let path: String

    private var db: OpaquePointer? {
        dbHandle.pointer
    }

    public init(path: String) throws {
        self.path = path
        if path != ":memory:" {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let dbPtr = handle else {
            let msg = handle != nil ? String(cString: sqlite3_errmsg(handle)) : "Failed to open sqlite"
            sqlite3_close(handle)
            throw NSError(domain: "Store", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        self.dbHandle = DBHandle(dbPtr)

        try Self.execute(db: dbPtr, sql: """
            CREATE TABLE IF NOT EXISTS calls (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                method TEXT NOT NULL,
                path TEXT NOT NULL,
                query TEXT NOT NULL DEFAULT '',
                status INTEGER,
                duration_ms INTEGER,
                req_headers TEXT NOT NULL DEFAULT '{}',
                req_body TEXT NOT NULL DEFAULT '',
                res_headers TEXT NOT NULL DEFAULT '{}',
                res_body TEXT NOT NULL DEFAULT '',
                error TEXT
            );
            CREATE INDEX IF NOT EXISTS calls_ts ON calls(ts DESC);
        """)
    }

    public func close() {
        if let ptr = dbHandle.pointer {
            sqlite3_close(ptr)
            dbHandle.pointer = nil
        }
    }

    private static func execute(db: OpaquePointer?, sql: String) throws {
        guard let db = db else { throw NSError(domain: "Store", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database closed"]) }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err != nil ? String(cString: err!) : "Unknown exec error"
            sqlite3_free(err)
            throw NSError(domain: "Store", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private func execute(sql: String) throws {
        try Self.execute(db: self.db, sql: sql)
    }

    @discardableResult
    public func insert(
        method: String,
        path: String,
        query: String = "",
        status: Int?,
        durationMs: Int?,
        reqHeaders: String,
        reqBody: String,
        resHeaders: String,
        resBody: String,
        error: String?
    ) throws -> Int64 {
        guard let db = db else { throw NSError(domain: "Store", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database closed"]) }
        let sql = """
            INSERT INTO calls (ts, method, path, query, status, duration_ms, req_headers, req_body, res_headers, res_body, error)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "Store", code: -1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        defer { sqlite3_finalize(stmt) }

        let now = Date().timeIntervalSince1970
        sqlite3_bind_double(stmt, 1, now)
        sqlite3_bind_text(stmt, 2, (method as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (path as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (query as NSString).utf8String, -1, nil)

        if let status = status {
            sqlite3_bind_int(stmt, 5, Int32(status))
        } else {
            sqlite3_bind_null(stmt, 5)
        }

        if let durationMs = durationMs {
            sqlite3_bind_int(stmt, 6, Int32(durationMs))
        } else {
            sqlite3_bind_null(stmt, 6)
        }

        sqlite3_bind_text(stmt, 7, (reqHeaders as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 8, (reqBody as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 9, (resHeaders as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 10, (resBody as NSString).utf8String, -1, nil)

        if let error = error {
            sqlite3_bind_text(stmt, 11, (error as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 11)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "Store", code: -1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }

        return sqlite3_last_insert_rowid(db)
    }

    public func listCalls(pathContains: String? = nil, limit: Int = 200) throws -> [CallSummary] {
        guard let db = db else { throw NSError(domain: "Store", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database closed"]) }
        var sql = "SELECT id, ts, method, path, query, status, duration_ms, error, res_body FROM calls"
        if pathContains != nil {
            sql += " WHERE path LIKE ?"
        }
        sql += " ORDER BY id DESC LIMIT ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "Store", code: -1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        defer { sqlite3_finalize(stmt) }

        var bindIdx: Int32 = 1
        if let pattern = pathContains {
            let needle = "%\(pattern)%"
            sqlite3_bind_text(stmt, bindIdx, (needle as NSString).utf8String, -1, nil)
            bindIdx += 1
        }
        sqlite3_bind_int(stmt, bindIdx, Int32(limit))

        var results: [CallSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let ts = sqlite3_column_double(stmt, 1)
            let method = String(cString: sqlite3_column_text(stmt, 2))
            let path = String(cString: sqlite3_column_text(stmt, 3))
            let query = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let status: Int? = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 5))
            let durationMs: Int? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 6))
            let error: String? = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            let resBody: String? = sqlite3_column_text(stmt, 8).map { String(cString: $0) }

            let usage = Annotate.extractUsage(resBody: resBody)
            let issue = Annotate.classifyIssue(status: status, resBody: resBody, error: error)

            results.append(CallSummary(
                id: id,
                ts: ts,
                method: method,
                path: path,
                query: query,
                status: status,
                durationMs: durationMs,
                error: error,
                promptTokens: usage.prompt,
                completionTokens: usage.completion,
                totalTokens: usage.total,
                issue: issue.id,
                issueLabel: issue.label
            ))
        }

        return results
    }

    public func getCall(id: Int64) throws -> CallDetail? {
        guard let db = db else { throw NSError(domain: "Store", code: -1, userInfo: [NSLocalizedDescriptionKey: "Database closed"]) }
        let sql = "SELECT id, ts, method, path, query, status, duration_ms, req_headers, req_body, res_headers, res_body, error FROM calls WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "Store", code: -1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, id)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        let cid = sqlite3_column_int64(stmt, 0)
        let ts = sqlite3_column_double(stmt, 1)
        let method = String(cString: sqlite3_column_text(stmt, 2))
        let path = String(cString: sqlite3_column_text(stmt, 3))
        let query = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
        let status: Int? = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 5))
        let durationMs: Int? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 6))
        let reqHeaders = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "{}"
        let reqBody = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
        let resHeaders = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? "{}"
        let resBody = sqlite3_column_text(stmt, 10).map { String(cString: $0) } ?? ""
        let error = sqlite3_column_text(stmt, 11).map { String(cString: $0) }

        let usage = Annotate.extractUsage(resBody: resBody)
        let issue = Annotate.classifyIssue(status: status, resBody: resBody, error: error)

        return CallDetail(
            id: cid,
            ts: ts,
            method: method,
            path: path,
            query: query,
            status: status,
            durationMs: durationMs,
            reqHeaders: reqHeaders,
            reqBody: reqBody,
            resHeaders: resHeaders,
            resBody: resBody,
            error: error,
            promptTokens: usage.prompt,
            completionTokens: usage.completion,
            totalTokens: usage.total,
            issue: issue.id,
            issueLabel: issue.label
        )
    }

    public func clear() throws {
        try execute(sql: "DELETE FROM calls;")
    }
}
