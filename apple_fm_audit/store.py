"""SQLite log of proxied HTTP calls."""

from __future__ import annotations

import json
import sqlite3
import threading
import time
from typing import Any

from apple_fm_audit.annotate import annotate_row


def _decode(body: bytes) -> str:
    if not body:
        return ""
    return body.decode("utf-8", errors="replace")


class Store:
    def __init__(self, path: str):
        self.path = path
        self._lock = threading.Lock()
        self.conn = sqlite3.connect(path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute(
            """
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
            )
            """
        )
        self.conn.execute(
            "CREATE INDEX IF NOT EXISTS calls_ts ON calls(ts DESC)"
        )
        self.conn.commit()

    def close(self) -> None:
        self.conn.close()

    def insert(
        self,
        *,
        method: str,
        path: str,
        query: str,
        status: int | None,
        duration_ms: int | None,
        req_headers: dict[str, str],
        req_body: bytes,
        res_headers: dict[str, str],
        res_body: bytes,
        error: str | None,
    ) -> int:
        with self._lock:
            cur = self.conn.execute(
            """
            INSERT INTO calls (
                ts, method, path, query, status, duration_ms,
                req_headers, req_body, res_headers, res_body, error
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                time.time(),
                method,
                path,
                query or "",
                status,
                duration_ms,
                json.dumps(req_headers),
                _decode(req_body),
                json.dumps(res_headers),
                _decode(res_body),
                error,
            ),
        )
            self.conn.commit()
            return int(cur.lastrowid)

    def list_calls(
        self, path_contains: str | None = None, limit: int = 200
    ) -> list[dict[str, Any]]:
        sql = (
            "SELECT id, ts, method, path, query, status, duration_ms, error, res_body "
            "FROM calls"
        )
        args: list[Any] = []
        if path_contains:
            sql += " WHERE path LIKE ?"
            args.append(f"%{path_contains}%")
        sql += " ORDER BY id DESC LIMIT ?"
        args.append(limit)
        with self._lock:
            rows = self.conn.execute(sql, args).fetchall()
        return [annotate_row(dict(r)) for r in rows]

    def get_call(self, call_id: int) -> dict[str, Any] | None:
        with self._lock:
            row = self.conn.execute(
                "SELECT * FROM calls WHERE id = ?", (call_id,)
            ).fetchone()
        if row is None:
            return None
        data = dict(row)
        extra = annotate_row(
            {
                "status": data.get("status"),
                "error": data.get("error"),
                "res_body": data.get("res_body"),
            }
        )
        data["prompt_tokens"] = extra["prompt_tokens"]
        data["completion_tokens"] = extra["completion_tokens"]
        data["total_tokens"] = extra["total_tokens"]
        data["issue"] = extra["issue"]
        data["issue_label"] = extra["issue_label"]
        return data

    def clear(self) -> None:
        with self._lock:
            self.conn.execute("DELETE FROM calls")
            self.conn.commit()
