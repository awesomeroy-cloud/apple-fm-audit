#!/usr/bin/env python3
import json
import unittest

from apple_fm_audit.convert import (
    chat_sse_line_to_response_frames,
    chat_to_response,
    is_responses_path,
    to_chat_request,
)


def _payloads(frames):
    out = []
    for frame in frames:
        for line in frame.split("\n"):
            if line.startswith("data:"):
                out.append(json.loads(line[5:].strip()))
    return out


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
        self.assertIsInstance(out["created_at"], (int, float))


class StreamEventsTest(unittest.TestCase):
    """Events must parse as openai.types.responses streaming models."""

    def test_delta_stream_matches_openai_sdk(self):
        from openai.types.responses.response_created_event import (
            ResponseCreatedEvent,
        )
        from openai.types.responses.response_text_delta_event import (
            ResponseTextDeltaEvent,
        )

        acc: dict = {}
        first = _payloads(
            chat_sse_line_to_response_frames(
                'data: {"id":"chatcmpl-1","created":99,"model":"system",'
                '"choices":[{"delta":{"content":"OK"}}]}\n',
                acc,
            )
        )
        types = [p["type"] for p in first]
        self.assertEqual(types[0], "response.created")
        ResponseCreatedEvent.model_validate(first[0])
        self.assertIsInstance(first[0]["sequence_number"], int)
        self.assertIsInstance(first[0]["response"]["created_at"], (int, float))
        delta = next(p for p in first if p["type"] == "response.output_text.delta")
        ResponseTextDeltaEvent.model_validate(delta)
        self.assertEqual(delta["delta"], "OK")
        self.assertEqual(delta["item_id"], "msg_1")
        self.assertEqual(delta["content_index"], 0)
        self.assertEqual(delta["output_index"], 0)
        self.assertEqual(delta["logprobs"], [])

    def test_completed_wraps_response_object(self):
        from openai.types.responses.response_completed_event import (
            ResponseCompletedEvent,
        )

        acc: dict = {
            "id": "chatcmpl-1",
            "created": 99,
            "model": "system",
            "text": "OK",
            "started": True,
        }
        done = _payloads(chat_sse_line_to_response_frames("data: [DONE]\n", acc))
        completed = next(p for p in done if p["type"] == "response.completed")
        ResponseCompletedEvent.model_validate(completed)
        self.assertEqual(
            completed["response"]["output"][0]["content"][0]["text"], "OK"
        )
        self.assertIsInstance(completed["response"]["created_at"], (int, float))


if __name__ == "__main__":
    unittest.main()
