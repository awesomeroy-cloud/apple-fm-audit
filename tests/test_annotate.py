#!/usr/bin/env python3
import unittest

from apple_fm_audit.annotate import classify_issue, extract_usage, parse_health


class ClassifyIssueTest(unittest.TestCase):
    def test_ok(self):
        self.assertEqual(
            classify_issue(200, '{"object":"chat.completion"}', None)["id"],
            "ok",
        )

    def test_csrf(self):
        body = '{"error":{"message":"Cross-site requests are not allowed.","type":"permission_denied"}}'
        self.assertEqual(classify_issue(403, body, None)["id"], "csrf")

    def test_invalid_model(self):
        body = '{"error":{"message":"Unknown model \'pcc\'. Available models: system","type":"invalid_request_error"}}'
        self.assertEqual(classify_issue(400, body, None)["id"], "invalid")

    def test_guardrail(self):
        body = '{"error":{"message":"GuardrailViolationError: content blocked"}}'
        self.assertEqual(classify_issue(400, body, None)["id"], "guardrail")

    def test_context(self):
        body = '{"error":{"message":"ExceededContextWindowSizeError"}}'
        self.assertEqual(classify_issue(400, body, None)["id"], "context")

    def test_assets(self):
        body = '{"error":{"message":"AssetsUnavailableError: model assets missing"}}'
        self.assertEqual(classify_issue(503, body, None)["id"], "assets")

    def test_proxy_broken_pipe(self):
        self.assertEqual(
            classify_issue(200, "", "[Errno 32] Broken pipe")["id"],
            "proxy",
        )


class ExtractUsageTest(unittest.TestCase):
    def test_chat_completion(self):
        body = '{"usage":{"prompt_tokens":57,"completion_tokens":19,"total_tokens":76}}'
        self.assertEqual(
            extract_usage(body),
            {"prompt_tokens": 57, "completion_tokens": 19, "total_tokens": 76},
        )

    def test_responses_object(self):
        body = '{"object":"response","usage":{"input_tokens":10,"output_tokens":4,"total_tokens":14}}'
        self.assertEqual(
            extract_usage(body),
            {"prompt_tokens": 10, "completion_tokens": 4, "total_tokens": 14},
        )

    def test_missing(self):
        self.assertEqual(
            extract_usage("not json"),
            {"prompt_tokens": None, "completion_tokens": None, "total_tokens": None},
        )


class ParseHealthTest(unittest.TestCase):
    def test_running(self):
        raw = '{"status":"fm serve is running","models":[{"available":true,"name":"system"}]}'
        out = parse_health(raw)
        self.assertTrue(out["reachable"])
        self.assertTrue(out["available"])
        self.assertEqual(out["name"], "system")
        self.assertEqual(out["reason"], "")

    def test_unavailable_reason(self):
        raw = '{"status":"fm serve is running","models":[{"available":false,"name":"system","reason":"Apple Intelligence is not enabled"}]}'
        out = parse_health(raw)
        self.assertFalse(out["available"])
        self.assertEqual(out["reason"], "Apple Intelligence is not enabled")


if __name__ == "__main__":
    unittest.main()
