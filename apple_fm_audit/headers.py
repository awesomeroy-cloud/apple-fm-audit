"""Which paths stay local, and which request headers may reach fm serve."""

from __future__ import annotations

HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "host",
    "origin",
    "referer",
}

LOCAL_FILES = {"/", "/app.css", "/app.js", "/favicon.ico"}


def is_local_path(path: str) -> bool:
    raw = path.split("?", 1)[0]
    if raw in LOCAL_FILES:
        return True
    return raw.startswith("/_audit/")


def upstream_headers(headers: dict[str, str]) -> dict[str, str]:
    out: dict[str, str] = {}
    for key, value in headers.items():
        lk = key.lower()
        if lk in HOP_BY_HOP or lk.startswith("sec-fetch-"):
            continue
        out[key] = value
    return out
