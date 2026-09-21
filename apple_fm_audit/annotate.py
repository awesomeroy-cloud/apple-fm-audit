"""Classify fm errors and pull token usage from stored bodies."""

from __future__ import annotations

import http.client
import json
from typing import Any


def _blob(*parts: Any) -> str:
    return " ".join(str(p) for p in parts if p).lower()


def classify_issue(
    status: int | None, res_body: str | None, error: str | None
) -> dict[str, str]:
    text = _blob(res_body, error)
    if "cross-site" in text or "csrf" in text:
        return {"id": "csrf", "label": "csrf"}
    if "guardrail" in text:
        return {"id": "guardrail", "label": "guardrail"}
    if "contextwindow" in text or "context window" in text or "prompt is too long" in text:
        return {"id": "context", "label": "context"}
    if "assetsunavailable" in text or "assets unavailable" in text:
        return {"id": "assets", "label": "assets"}
    if "broken pipe" in text or "proxy_error" in text or "upstream" in text:
        return {"id": "proxy", "label": "proxy"}
    if status is not None and status >= 400:
        if "invalid_request" in text or "unknown model" in text or status == 400:
            return {"id": "invalid", "label": "invalid"}
        if status >= 500:
            return {"id": "server", "label": "server"}
        return {"id": "client", "label": "client"}
    return {"id": "ok", "label": "ok"}


def extract_usage(res_body: str | None) -> dict[str, int | None]:
    empty = {
        "prompt_tokens": None,
        "completion_tokens": None,
        "total_tokens": None,
    }
    if not res_body:
        return empty
    try:
        payload = json.loads(res_body)
    except (ValueError, TypeError):
        return empty
    if not isinstance(payload, dict):
        return empty
    usage = payload.get("usage")
    if not isinstance(usage, dict):
        return empty
    prompt = usage.get("prompt_tokens", usage.get("input_tokens"))
    completion = usage.get("completion_tokens", usage.get("output_tokens"))
    total = usage.get("total_tokens")
    try:
        prompt_n = int(prompt) if prompt is not None else None
        completion_n = int(completion) if completion is not None else None
        total_n = int(total) if total is not None else None
    except (TypeError, ValueError):
        return empty
    if total_n is None and prompt_n is not None and completion_n is not None:
        total_n = prompt_n + completion_n
    return {
        "prompt_tokens": prompt_n,
        "completion_tokens": completion_n,
        "total_tokens": total_n,
    }


def parse_health(raw: str) -> dict[str, Any]:
    try:
        payload = json.loads(raw)
    except (ValueError, TypeError):
        return {
            "reachable": False,
            "available": False,
            "name": "",
            "reason": "health is not JSON",
            "models": [],
        }
    models = payload.get("models") if isinstance(payload, dict) else None
    if not isinstance(models, list) or not models:
        return {
            "reachable": True,
            "available": False,
            "name": "",
            "reason": "no models in /health",
            "models": [],
        }
    first = models[0] if isinstance(models[0], dict) else {}
    available = bool(first.get("available"))
    reason = str(first.get("reason") or "")
    if not available and not reason:
        reason = "system model unavailable"
    return {
        "reachable": True,
        "available": available,
        "name": str(first.get("name") or ""),
        "reason": reason if not available else "",
        "models": models,
    }


def inspect_upstream(host: str, port: int) -> dict[str, Any]:
    try:
        conn = http.client.HTTPConnection(host, port, timeout=1.5)
        conn.request("GET", "/health")
        resp = conn.getresponse()
        raw = resp.read().decode("utf-8", errors="replace")
        conn.close()
    except Exception as exc:
        return {
            "reachable": False,
            "available": False,
            "name": "",
            "reason": str(exc),
            "models": [],
        }
    parsed = parse_health(raw)
    if resp.status >= 400 and parsed["available"]:
        parsed["available"] = False
        parsed["reason"] = parsed["reason"] or f"health HTTP {resp.status}"
    return parsed


def annotate_row(row: dict[str, Any]) -> dict[str, Any]:
    body = row.pop("res_body", "") or ""
    usage = extract_usage(body)
    issue = classify_issue(row.get("status"), body, row.get("error"))
    out = dict(row)
    out.update(usage)
    out["issue"] = issue["id"]
    out["issue_label"] = issue["label"]
    return out
