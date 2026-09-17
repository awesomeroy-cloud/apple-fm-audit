#!/usr/bin/env python3
import json
import os
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import Request, urlopen

from apple_fm_audit.server import AuditServer
from apple_fm_audit.store import Store


class Upstream(BaseHTTPRequestHandler):
    def log_message(self, *args):
        return

    def do_GET(self):
        origin = self.headers.get("Origin")
        body = json.dumps({"origin": origin, "path": self.path}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    last_path = ""
    last_body = b""

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n)
        Upstream.last_path = self.path
        Upstream.last_body = raw
        if self.path.startswith("/v1/chat/completions"):
            raw = json.dumps(
                {
                    "id": "chatcmpl-1",
                    "object": "chat.completion",
                    "created": 1,
                    "model": "system",
                    "choices": [
                        {
                            "index": 0,
                            "message": {
                                "role": "assistant",
                                "content": "OK",
                            },
                            "finish_reason": "stop",
                        }
                    ],
                    "usage": {
                        "prompt_tokens": 1,
                        "completion_tokens": 1,
                        "total_tokens": 2,
                    },
                }
            ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


class ProxyTest(unittest.TestCase):
    def setUp(self):
        self.up = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        self.up_thread = threading.Thread(target=self.up.serve_forever, daemon=True)
        self.up_thread.start()
        fd, self.db = tempfile.mkstemp(suffix=".sqlite")
        os.close(fd)
        self.store = Store(self.db)
        up_port = self.up.server_address[1]
        self.audit = AuditServer(
            ("127.0.0.1", 0), ("127.0.0.1", up_port), self.store
        )
        self.audit_thread = threading.Thread(
            target=self.audit.serve_forever, daemon=True
        )
        self.audit_thread.start()
        self.base = "http://127.0.0.1:%s" % self.audit.server_address[1]
        time.sleep(0.05)

    def tearDown(self):
        self.audit.shutdown()
        self.audit.server_close()
        self.up.shutdown()
        self.up.server_close()
        self.store.close()
        os.unlink(self.db)

    def test_strips_origin_and_records_body(self):
        req = Request(
            self.base + "/v1/models",
            headers={"Origin": "https://example.test"},
        )
        with urlopen(req, timeout=5) as res:
            payload = json.loads(res.read().decode())
        self.assertIsNone(payload["origin"])
        rows = self.store.list_calls()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["path"], "/v1/models")
        self.assertEqual(rows[0]["status"], 200)

    def test_post_body_roundtrip(self):
        data = b'{"model":"system","messages":[{"role":"user","content":"hi"}]}'
        req = Request(
            self.base + "/v1/chat/completions",
            data=data,
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        with urlopen(req, timeout=5) as res:
            payload = json.loads(res.read().decode())
        self.assertEqual(payload["choices"][0]["message"]["content"], "OK")
        row = self.store.get_call(self.store.list_calls()[0]["id"])
        self.assertIn("hi", row["req_body"])

    def test_ui_is_not_proxied(self):
        with urlopen(self.base + "/", timeout=5) as res:
            html = res.read().decode()
        self.assertIn("apple-fm-audit", html)

    def test_responses_translates_to_chat_completions(self):
        payload = json.dumps(
            {
                "model": "system",
                "input": [
                    {
                        "type": "message",
                        "role": "user",
                        "content": [{"type": "input_text", "text": "Say OK"}],
                    }
                ],
                "stream": False,
            }
        ).encode()
        req = Request(
            self.base + "/v1/responses",
            data=payload,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "Origin": "https://example.test",
            },
        )
        with urlopen(req, timeout=5) as res:
            body = json.loads(res.read().decode())
        self.assertEqual(body["object"], "response")
        self.assertEqual(body["output"][0]["content"][0]["text"], "OK")
        self.assertEqual(Upstream.last_path, "/v1/chat/completions")
        forwarded = json.loads(Upstream.last_body.decode())
        self.assertEqual(forwarded["messages"][-1]["content"], "Say OK")
        row = self.store.get_call(self.store.list_calls()[0]["id"])
        self.assertEqual(row["path"], "/v1/responses")
        self.assertIn("input_text", row["req_body"])


if __name__ == "__main__":
    unittest.main()
