#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p data
export AFM_LISTEN_HOST="${AFM_LISTEN_HOST:-127.0.0.1}"
export AFM_LISTEN_PORT="${AFM_LISTEN_PORT:-1977}"
export AFM_UPSTREAM="${AFM_UPSTREAM:-127.0.0.1:1976}"
export AFM_DB="${AFM_DB:-$PWD/data/audit.sqlite}"
exec python3 -m apple_fm_audit
