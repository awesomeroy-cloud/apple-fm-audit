"""PCC availability and on-device fallback.

Apple: check PrivateCloudComputeLanguageModel.availability before a request.
If the PCC request fails because the network is down, retry on-device.
"""

from __future__ import annotations

import json
from typing import Any

PCC_IDS = {
    "pcc",
    "private-cloud-compute",
    "privatecloudcompute",
    "private_cloud_compute",
    "afm-pcc",
}

NETWORK_MARKERS = (
    "networkfailure",
    "network connection",
    "not connected to the internet",
    "internet connection appears to be offline",
    "the network connection was lost",
    "nsurlerror",
    "timed out",
    "timeout",
    "connection reset",
    "no route to host",
    "offline",
)


def is_pcc_model(name: str | None) -> bool:
    if not name:
        return False
    key = name.strip().lower().replace("_", "-")
    return key in PCC_IDS or key == "pcc"


def _entry(models: list[Any], name: str) -> dict[str, Any] | None:
    for item in models:
        if isinstance(item, dict) and str(item.get("name") or "") == name:
            return item
    return None


def pcc_availability(health: dict[str, Any]) -> dict[str, str]:
    if not health.get("reachable"):
        return {
            "state": "unreachable",
            "reason": str(health.get("reason") or "upstream down"),
        }
    models = health.get("models") or []
    if not isinstance(models, list):
        models = []
    entry = _entry(models, "pcc")
    if entry is None:
        return {
            "state": "unsupported",
            "reason": "fm has no pcc; macOS 27.2 restored it",
        }
    if entry.get("available"):
        return {"state": "available", "reason": ""}
    raw = str(entry.get("reason") or "")
    low = raw.lower().replace(" ", "")
    if "devicenoteligible" in low or "not eligible" in raw.lower():
        return {"state": "deviceNotEligible", "reason": raw or "deviceNotEligible"}
    if "systemnotready" in low or "not ready" in raw.lower():
        return {"state": "systemNotReady", "reason": raw or "systemNotReady"}
    return {"state": "unavailable", "reason": raw or "unavailable"}


def choose_model(requested: str | None, health: dict[str, Any]) -> tuple[str, str | None]:
    name = (requested or "system").strip() or "system"
    if not is_pcc_model(name):
        return name, None
    info = pcc_availability(health)
    if info["state"] == "available":
        return "pcc", None
    return "system", f"pcc {info['state']}: {info['reason']}"


def is_network_failure(
    status: int | None, res_body: str | None, error: str | None
) -> bool:
    text = " ".join(str(p) for p in (res_body, error) if p).lower()
    if not text:
        return False
    if "unknown model" in text:
        return False
    return any(marker in text for marker in NETWORK_MARKERS)


def requested_model(body: bytes) -> str | None:
    if not body:
        return None
    try:
        payload = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(payload, dict):
        return None
    model = payload.get("model")
    return str(model) if model is not None else None


def set_json_model(body: bytes, model: str) -> bytes:
    if not body:
        return json.dumps({"model": model}, ensure_ascii=False).encode("utf-8")
    try:
        payload = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return body
    if not isinstance(payload, dict):
        return body
    payload["model"] = model
    return json.dumps(payload, ensure_ascii=False).encode("utf-8")
