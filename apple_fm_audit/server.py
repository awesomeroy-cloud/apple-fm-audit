"""HTTP server: audit UI on /, reverse proxy everything else to fm serve."""

from __future__ import annotations

import http.client
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from apple_fm_audit.headers import is_local_path, upstream_headers
from apple_fm_audit.store import Store

ROOT = Path(__file__).resolve().parent.parent
STATIC = ROOT / "static"
MAX_BODY = 8 * 1024 * 1024


def env(name: str, default: str) -> str:
    value = os.environ.get(name)
    return default if value is None or value == "" else value


class AuditHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s · %s\n" % (self.log_date_time_string(), fmt % args))

    def do_GET(self) -> None:
        self._dispatch()

    def do_POST(self) -> None:
        self._dispatch()

    def do_PUT(self) -> None:
        self._dispatch()

    def do_PATCH(self) -> None:
        self._dispatch()

    def do_DELETE(self) -> None:
        self._dispatch()

    def do_HEAD(self) -> None:
        self._dispatch()

    def do_OPTIONS(self) -> None:
        self._dispatch()

    def _dispatch(self) -> None:
        parsed = urlsplit(self.path)
        if is_local_path(parsed.path):
            self._local(parsed)
            return
        self._proxy(parsed)

    def _local(self, parsed) -> None:
        path = parsed.path
        if path == "/":
            self._file(STATIC / "index.html", "text/html; charset=utf-8")
            return
        if path == "/app.css":
            self._file(STATIC / "app.css", "text/css; charset=utf-8")
            return
        if path == "/app.js":
            self._file(STATIC / "app.js", "text/javascript; charset=utf-8")
            return
        if path == "/favicon.ico":
            self._file(STATIC / "favicon.svg", "image/svg+xml")
            return
        if self.command == "GET" and path == "/_audit/meta":
            self._json(200, self.server.meta)  # type: ignore[attr-defined]
            return
        if self.command == "GET" and path == "/_audit/calls":
            q = parse_qs(parsed.query)
            needle = (q.get("q") or [None])[0]
            rows = self.server.store.list_calls(path_contains=needle)  # type: ignore[attr-defined]
            self._json(200, {"calls": rows})
            return
        if self.command == "GET" and path.startswith("/_audit/calls/"):
            rest = path[len("/_audit/calls/") :]
            try:
                call_id = int(rest)
            except ValueError:
                self._json(404, {"error": "not found"})
                return
            row = self.server.store.get_call(call_id)  # type: ignore[attr-defined]
            if row is None:
                self._json(404, {"error": "not found"})
                return
            self._json(200, row)
            return
        if self.command == "DELETE" and path == "/_audit/calls":
            self.server.store.clear()  # type: ignore[attr-defined]
            self._json(200, {"ok": True})
            return
        self._json(404, {"error": "not found"})

    def _file(self, path: Path, content_type: str) -> None:
        if not path.is_file():
            self._json(404, {"error": "missing static file"})
            return
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _json(self, status: int, payload: dict) -> None:
        data = json.dumps(payload, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _proxy(self, parsed) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            self._json(413, {"error": "request body too large"})
            return
        req_body = self.rfile.read(length) if length else b""
        req_headers = {k: v for k, v in self.headers.items()}
        fwd = upstream_headers(req_headers)
        if req_body:
            fwd["Content-Length"] = str(len(req_body))
        else:
            fwd.pop("Content-Length", None)

        host, port = self.server.upstream  # type: ignore[attr-defined]
        started = time.perf_counter()
        status = None
        res_headers: dict[str, str] = {}
        res_body = b""
        error = None
        conn = http.client.HTTPConnection(host, port, timeout=600)
        try:
            conn.request(
                self.command,
                parsed.path + (("?" + parsed.query) if parsed.query else ""),
                body=req_body or None,
                headers=fwd,
            )
            resp = conn.getresponse()
            status = resp.status
            res_headers = {k: v for k, v in resp.getheaders()}
            self.send_response(resp.status, resp.reason)
            hop = {
                "connection",
                "keep-alive",
                "transfer-encoding",
                "content-length",
            }
            ctype = (resp.getheader("Content-Type") or "").lower()
            streaming = "text/event-stream" in ctype
            for k, v in resp.getheaders():
                if k.lower() in hop:
                    continue
                self.send_header(k, v)
            chunks: list[bytes] = []
            if streaming:
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "close")
                self.end_headers()
                while True:
                    chunk = resp.read(8192)
                    if not chunk:
                        break
                    chunks.append(chunk)
                    if self.command != "HEAD":
                        self.wfile.write(chunk)
                        self.wfile.flush()
            else:
                data = resp.read()
                chunks.append(data)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(data)
            res_body = b"".join(chunks)
        except Exception as exc:
            error = str(exc)
            if not self.wfile.closed:
                try:
                    self._json(
                        502,
                        {
                            "error": {
                                "message": f"upstream {host}:{port}: {exc}",
                                "type": "proxy_error",
                            }
                        },
                    )
                except Exception:
                    pass
        finally:
            conn.close()
            duration_ms = int((time.perf_counter() - started) * 1000)
            try:
                self.server.store.insert(  # type: ignore[attr-defined]
                    method=self.command,
                    path=parsed.path,
                    query=parsed.query,
                    status=status,
                    duration_ms=duration_ms,
                    req_headers=req_headers,
                    req_body=req_body,
                    res_headers=res_headers,
                    res_body=res_body,
                    error=error,
                )
            except Exception as exc:
                sys.stderr.write("store insert failed: %s\n" % exc)


class AuditServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        bind: tuple[str, int],
        upstream: tuple[str, int],
        store: Store,
    ):
        super().__init__(bind, AuditHandler)
        self.upstream = upstream
        self.store = store
        self.meta = {
            "listen": f"{bind[0]}:{bind[1]}",
            "upstream": f"{upstream[0]}:{upstream[1]}",
            "db": store.path,
        }


def parse_hostport(value: str, default_port: int) -> tuple[str, int]:
    if ":" in value:
        host, _, port_s = value.rpartition(":")
        return host or "127.0.0.1", int(port_s)
    return value, default_port


def main() -> int:
    listen_host = env("AFM_LISTEN_HOST", "127.0.0.1")
    listen_port = int(env("AFM_LISTEN_PORT", "1977"))
    upstream = parse_hostport(env("AFM_UPSTREAM", "127.0.0.1:1976"), 1976)
    db_path = env("AFM_DB", str(ROOT / "data" / "audit.sqlite"))
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    store = Store(db_path)
    httpd = AuditServer((listen_host, listen_port), upstream, store)
    print(
        "apple-fm-audit\n"
        f"  ui       http://{listen_host}:{listen_port}\n"
        f"  upstream http://{upstream[0]}:{upstream[1]}\n"
        f"  sqlite   {db_path}\n"
        "  clients  point OpenAI base URL at this origin",
        flush=True,
    )
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped", flush=True)
    finally:
        store.close()
    return 0
