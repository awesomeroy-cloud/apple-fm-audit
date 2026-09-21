#!/usr/bin/env python3
import os
import tempfile
import unittest

from apple_fm_audit.store import Store


class StoreTest(unittest.TestCase):
    def setUp(self):
        fd, self.path = tempfile.mkstemp(suffix=".sqlite")
        os.close(fd)
        self.store = Store(self.path)

    def tearDown(self):
        self.store.close()
        os.unlink(self.path)

    def test_insert_and_list(self):
        call_id = self.store.insert(
            method="POST",
            path="/v1/chat/completions",
            query="",
            status=200,
            duration_ms=12,
            req_headers={"content-type": "application/json"},
            req_body=b'{"model":"system"}',
            res_headers={"content-type": "application/json"},
            res_body=b'{"ok":true}',
            error=None,
        )
        rows = self.store.list_calls()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["id"], call_id)
        self.assertEqual(rows[0]["method"], "POST")
        self.assertEqual(rows[0]["path"], "/v1/chat/completions")
        self.assertEqual(rows[0]["status"], 200)

    def test_list_annotates_usage_and_issue(self):
        self.store.insert(
            method="POST",
            path="/v1/chat/completions",
            query="",
            status=400,
            duration_ms=4,
            req_headers={},
            req_body=b"{}",
            res_headers={},
            res_body=b'{"error":{"message":"ExceededContextWindowSizeError"},"usage":{"prompt_tokens":9000,"completion_tokens":0,"total_tokens":9000}}',
            error=None,
        )
        row = self.store.list_calls()[0]
        self.assertEqual(row["issue"], "context")
        self.assertEqual(row["prompt_tokens"], 9000)
        self.assertNotIn("res_body", row)

    def test_get_includes_bodies(self):
        call_id = self.store.insert(
            method="GET",
            path="/v1/models",
            query="",
            status=200,
            duration_ms=3,
            req_headers={},
            req_body=b"",
            res_headers={},
            res_body=b'{"object":"list"}',
            error=None,
        )
        row = self.store.get_call(call_id)
        self.assertEqual(row["res_body"], '{"object":"list"}')

    def test_clear(self):
        self.store.insert(
            method="GET",
            path="/health",
            query="",
            status=200,
            duration_ms=1,
            req_headers={},
            req_body=b"",
            res_headers={},
            res_body=b"ok",
            error=None,
        )
        self.store.clear()
        self.assertEqual(self.store.list_calls(), [])

    def test_filter_path(self):
        self.store.insert(
            method="GET",
            path="/v1/models",
            query="",
            status=200,
            duration_ms=1,
            req_headers={},
            req_body=b"",
            res_headers={},
            res_body=b"",
            error=None,
        )
        self.store.insert(
            method="POST",
            path="/v1/chat/completions",
            query="",
            status=200,
            duration_ms=1,
            req_headers={},
            req_body=b"",
            res_headers={},
            res_body=b"",
            error=None,
        )
        rows = self.store.list_calls(path_contains="chat")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["path"], "/v1/chat/completions")


if __name__ == "__main__":
    unittest.main()
