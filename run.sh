#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p data
export AFM_LISTEN_HOST="${AFM_LISTEN_HOST:-127.0.0.1}"
# LAN: AFM_LISTEN_HOST=0.0.0.0 ./run.sh
export AFM_LISTEN_PORT="${AFM_LISTEN_PORT:-1977}"
export AFM_UPSTREAM="${AFM_UPSTREAM:-127.0.0.1:1976}"
export AFM_DB="${AFM_DB:-$PWD/data/audit.sqlite}"
export AFM_STATIC_DIR="${AFM_STATIC_DIR:-$PWD/static}"

if [ ! -x ".build/release/apple-fm-audit" ]; then
  echo "Building release binary..."
  if [ -d "/Applications/Xcode-beta.app/Contents/Developer" ]; then
    DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build -c release
  else
    swift build -c release
  fi
fi

exec .build/release/apple-fm-audit
