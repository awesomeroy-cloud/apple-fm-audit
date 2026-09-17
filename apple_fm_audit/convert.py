"""Normalize OpenAI Responses / Chat Completions JSON into what `fm serve` decodes.

`fm serve` is Chat Completions only. A browser SDK posting `/responses` with
`content: [{type: "input_text"}]` or `role: "developer"` returns:

  Invalid JSON: The data couldn't be read because it isn't in the correct format.

That is Swift Codable typeMismatch. Same mapping as fm-proxy for `developer`.
"""

from __future__ import annotations

import json
from typing import Any

KEEP = {
    "model",
    "messages",
    "stream",
    "temperature",
    "max_tokens",
    "max_completion_tokens",
    "response_format",
    "tools",
    "tool_choice",
    "stream_options",
    "n",
    "user",
}


def flatten_content(content: Any) -> Any:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, dict):
        return flatten_content([content])
    if not isinstance(content, list):
        return str(content)
    texts: list[str] = []
    images: list[dict[str, Any]] = []
    for part in content:
        if isinstance(part, str):
            texts.append(part)
            continue
        if not isinstance(part, dict):
            continue
        kind = part.get("type")
        if kind in (None, "text", "input_text", "output_text"):
            texts.append(str(part.get("text") or ""))
        elif kind in ("image_url", "input_image"):
            url = part.get("image_url") or part.get("url")
            if isinstance(url, str):
                images.append({"type": "image_url", "image_url": {"url": url}})
            elif isinstance(url, dict):
                images.append({"type": "image_url", "image_url": url})
    if images:
        parts: list[dict[str, Any]] = []
        if texts:
            parts.append({"type": "text", "text": "\n".join(texts)})
        parts.extend(images)
        return parts
    return "\n".join(texts)


def map_role(role: Any) -> str:
    if role in ("developer", "system"):
        return "system"
    if role == "assistant":
        return "assistant"
    if role in ("tool", "function"):
        return "tool"
    return "user"


def _normalize_message(item: dict[str, Any]) -> dict[str, Any]:
    msg: dict[str, Any] = {
        "role": map_role(item.get("role")),
        "content": flatten_content(item.get("content")),
    }
    if item.get("tool_call_id"):
        msg["tool_call_id"] = item["tool_call_id"]
    if item.get("name"):
        msg["name"] = item["name"]
    return msg


def _input_items_to_messages(src: Any) -> list[dict[str, Any]]:
    if isinstance(src, str):
        return [{"role": "user", "content": src}]
    if not isinstance(src, list):
        return []
    messages: list[dict[str, Any]] = []
    for item in src:
        if isinstance(item, str):
            messages.append({"role": "user", "content": item})
            continue
        if not isinstance(item, dict):
            continue
        kind = item.get("type")
        if kind in (None, "message"):
            messages.append(_normalize_message(item))
        elif kind in ("input_text", "output_text", "text"):
            messages.append({"role": "user", "content": str(item.get("text") or "")})
        elif kind == "function_call_output":
            messages.append(
                {
                    "role": "tool",
                    "content": flatten_content(item.get("output") or item.get("content")),
                    "tool_call_id": item.get("call_id") or item.get("id") or "",
                }
            )
        elif kind in ("function_call", "reasoning"):
            continue
        else:
            if "content" in item or "role" in item:
                messages.append(_normalize_message(item))
    return messages


def _fix_tools(tools: Any) -> list[dict[str, Any]] | None:
    if not isinstance(tools, list):
        return None
    out: list[dict[str, Any]] = []
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        fn = tool.get("function")
        if isinstance(fn, dict):
            desc = fn.get("description")
            out.append(
                {
                    "type": "function",
                    "function": {
                        **fn,
                        "description": "" if desc is None else desc,
                    },
                }
            )
            continue
        if tool.get("type") == "function" or "name" in tool:
            params = tool.get("parameters") or {"type": "object", "properties": {}}
            out.append(
                {
                    "type": "function",
                    "function": {
                        "name": tool.get("name") or "tool",
                        "description": tool.get("description") or "",
                        "parameters": params,
                    },
                }
            )
    return out


def to_chat_request(payload: dict[str, Any]) -> dict[str, Any]:
    messages: list[dict[str, Any]] = []
    instructions = payload.get("instructions")
    if isinstance(instructions, str) and instructions:
        messages.append({"role": "system", "content": instructions})

    if "messages" in payload:
        for item in payload["messages"] or []:
            if isinstance(item, dict):
                messages.append(_normalize_message(item))
            elif isinstance(item, str):
                messages.append({"role": "user", "content": item})
    else:
        messages.extend(_input_items_to_messages(payload.get("input")))

    out: dict[str, Any] = {k: v for k, v in payload.items() if k in KEEP}
    out["messages"] = messages
    out.setdefault("model", "system")

    if "max_output_tokens" in payload and "max_tokens" not in out:
        out["max_tokens"] = payload["max_output_tokens"]

    if "stream" in out and not isinstance(out["stream"], bool):
        out["stream"] = str(out["stream"]).lower() in ("1", "true", "yes")
    if "temperature" in out and isinstance(out["temperature"], str):
        try:
            out["temperature"] = float(out["temperature"])
        except ValueError:
            del out["temperature"]

    if out.get("stream") is True:
        opts = out.get("stream_options")
        if not isinstance(opts, dict):
            opts = {}
        if "include_usage" not in opts:
            opts["include_usage"] = True
        out["stream_options"] = opts
    elif "stream" not in out:
        out["stream"] = False

    tools = _fix_tools(payload.get("tools"))
    if tools is not None:
        out["tools"] = tools

    choice = out.get("tool_choice")
    if isinstance(choice, dict) or choice == "required":
        out.pop("tool_choice", None)

    if not messages:
        out["messages"] = [{"role": "user", "content": ""}]
    return out


def chat_to_response(chat: dict[str, Any]) -> dict[str, Any]:
    choices = chat.get("choices") or []
    message = (choices[0].get("message") if choices else {}) or {}
    text = message.get("content") or ""
    usage = chat.get("usage") or {}
    cid = str(chat.get("id") or "chatcmpl-local")
    rid = cid.replace("chatcmpl-", "resp_", 1)
    mid = cid.replace("chatcmpl-", "msg_", 1)
    return {
        "id": rid,
        "object": "response",
        "created_at": chat.get("created"),
        "status": "completed",
        "model": chat.get("model") or "system",
        "output": [
            {
                "id": mid,
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [
                    {"type": "output_text", "text": text, "annotations": []}
                ],
            }
        ],
        "usage": {
            "input_tokens": usage.get("prompt_tokens") or 0,
            "output_tokens": usage.get("completion_tokens") or 0,
            "total_tokens": usage.get("total_tokens") or 0,
            "input_tokens_details": {"cached_tokens": 0},
            "output_tokens_details": {"reasoning_tokens": 0},
        },
    }


def is_responses_path(path: str) -> bool:
    p = path.split("?", 1)[0]
    return p in ("/responses", "/v1/responses")


def rewrite_upstream(path: str, body: bytes) -> tuple[str, bytes, bool]:
    """Map Responses API POST onto /v1/chat/completions. Other paths unchanged."""
    if not is_responses_path(path):
        return path, body, False
    if not body:
        payload: dict = {}
    else:
        try:
            loaded = json.loads(body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return "/v1/chat/completions", body, True
        payload = loaded if isinstance(loaded, dict) else {}
    out = json.dumps(to_chat_request(payload)).encode("utf-8")
    return "/v1/chat/completions", out, True


def chat_sse_line_to_response_frames(
    line: str, acc: dict[str, Any]
) -> list[str]:
    """Turn one Chat Completions SSE line into Responses API SSE frames."""
    raw = line.strip()
    if not raw.startswith("data:"):
        return []
    payload = raw[5:].strip()
    if payload == "[DONE]":
        if acc.get("completed"):
            return []
        acc["completed"] = True
        body = chat_to_response(
            {
                "id": acc.get("id") or "chatcmpl-local",
                "created": acc.get("created") or 0,
                "model": acc.get("model") or "system",
                "choices": [
                    {
                        "message": {
                            "role": "assistant",
                            "content": acc.get("text") or "",
                        }
                    }
                ],
                "usage": acc.get("usage") or {},
            }
        )
        return [f"event: response.completed\ndata: {json.dumps(body)}\n\n"]
    try:
        obj = json.loads(payload)
    except ValueError:
        return []
    if not isinstance(obj, dict):
        return []
    if obj.get("id"):
        acc["id"] = obj["id"]
    if obj.get("created"):
        acc["created"] = obj["created"]
    if obj.get("model"):
        acc["model"] = obj["model"]
    if obj.get("usage"):
        acc["usage"] = obj["usage"]
    frames: list[str] = []
    if not acc.get("started"):
        acc["started"] = True
        created = {
            "type": "response.created",
            "response": {
                "id": str(acc.get("id") or "resp_local").replace(
                    "chatcmpl-", "resp_", 1
                ),
                "object": "response",
                "status": "in_progress",
                "model": acc.get("model") or "system",
            },
        }
        frames.append(
            f"event: response.created\ndata: {json.dumps(created)}\n\n"
        )
    choices = obj.get("choices") or []
    delta = (choices[0].get("delta") if choices else {}) or {}
    piece = delta.get("content")
    if isinstance(piece, str) and piece:
        acc["text"] = (acc.get("text") or "") + piece
        event = {
            "type": "response.output_text.delta",
            "delta": piece,
        }
        frames.append(
            f"event: response.output_text.delta\ndata: {json.dumps(event)}\n\n"
        )
    finish = choices[0].get("finish_reason") if choices else None
    if finish and not acc.get("completed"):
        acc["completed"] = True
        body = chat_to_response(
            {
                "id": acc.get("id") or "chatcmpl-local",
                "created": acc.get("created") or 0,
                "model": acc.get("model") or "system",
                "choices": [
                    {
                        "message": {
                            "role": "assistant",
                            "content": acc.get("text") or "",
                        }
                    }
                ],
                "usage": acc.get("usage") or {},
            }
        )
        frames.append(
            f"event: response.completed\ndata: {json.dumps(body)}\n\n"
        )
    return frames
