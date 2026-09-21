#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p data
export AFM_LISTEN_HOST="${AFM_LISTEN_HOST:-127.0.0.1}"
# LAN: AFM_LISTEN_HOST=0.0.0.0 ./run.sh
export AFM_LISTEN_PORT="${AFM_LISTEN_PORT:-1977}"
export AFM_UPSTREAM="${AFM_UPSTREAM:-127.0.0.1:1976}"
export AFM_DB="${AFM_DB:-$PWD/data/audit.sqlite}"
export PYTHONPATH="$PWD"

if ! command -v uv >/dev/null 2>&1; then
  echo "uv is required. Install: https://docs.astral.sh/uv/" >&2
  exit 1
fi

uv sync --frozen

echo "fm license:"
if ! uv run python -m apple_fm_audit.license_check; then
  echo "Starting the audit UI so you can read the notice in the browser."
fi

exec uv run python -m apple_fm_audit
