"""Read Apple's `fm license` gate. Never accept the terms on the user's behalf."""

from __future__ import annotations

import os
import shutil
import subprocess
from typing import Any

FM_BIN = os.environ.get("AFM_FM_BIN", "fm")


def parse_status(text: str, returncode: int) -> bool:
    blob = f"{text or ''}"
    low = blob.lower()
    if "have not agreed" in low or "not agreed" in low:
        return False
    if returncode != 0:
        return False
    return "agreed to license" in low or low.strip().startswith("agreed")


def _run(args: list[str]) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            args,
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except FileNotFoundError:
        return 127, f"{args[0]} not found"
    except subprocess.TimeoutExpired:
        return 124, "timed out"
    out = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode, out


def inspect_license(fm_bin: str | None = None) -> dict[str, Any]:
    binary = fm_bin or shutil.which(FM_BIN) or FM_BIN
    resolved = shutil.which(binary) or binary
    code, status_text = _run([resolved, "license", "--status"])
    agreed = parse_status(status_text, code)
    show_text = ""
    if not agreed:
        _show_code, show_text = _run([resolved, "license", "--show"])
        if not show_text.strip():
            show_text = status_text
    return {
        "agreed": agreed,
        "fm": resolved,
        "status": status_text.strip(),
        "text": show_text.strip(),
        "command": "sudo fm license",
    }


def main() -> int:
    info = inspect_license()
    print(info["status"] or info["fm"])
    if info["agreed"]:
        return 0
    if info["text"]:
        print()
        print(info["text"])
    print()
    print("Agree on this Mac with:", info["command"])
    print("This app will not type yes. After agreeing, run: fm serve")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
