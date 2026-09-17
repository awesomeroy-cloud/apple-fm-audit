#!/usr/bin/env python3
import unittest

from apple_fm_audit.convert import chat_to_response, is_responses_path, to_chat_request


class ConvertTest(unittest.TestCase):
    def test_input_text_parts_become_string(self):
        out = to_chat_request(
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
                "store": False,
            }
        )
        self.assertEqual(out["messages"][-1]["content"], "Say OK")
        self.assertNotIn("input", out)
        self.assertNotIn("store", out)

    def test_developer_role_becomes_system(self):
        out = to_chat_request(
            {
                "model": "system",
                "messages": [
                    {
                        "role": "developer",
                        "content": [{"type": "input_text", "text": "Be brief"}],
                    },
                    {"role": "user", "content": "Hi"},
                ],
            }
        )
        self.assertEqual(out["messages"][0]["role"], "system")
        self.assertEqual(out["messages"][0]["content"], "Be brief")

    def test_responses_paths(self):
        self.assertTrue(is_responses_path("/v1/responses"))
        self.assertTrue(is_responses_path("/responses"))
        self.assertFalse(is_responses_path("/v1/chat/completions"))

    def test_chat_to_response_object(self):
        out = chat_to_response(
            {
                "id": "chatcmpl-ABC",
                "created": 1,
                "model": "system",
                "choices": [
                    {"message": {"role": "assistant", "content": "OK"}}
                ],
                "usage": {
                    "prompt_tokens": 10,
                    "completion_tokens": 2,
                    "total_tokens": 12,
                },
            }
        )
        self.assertEqual(out["object"], "response")
        self.assertEqual(out["output"][0]["content"][0]["text"], "OK")


if __name__ == "__main__":
    unittest.main()
