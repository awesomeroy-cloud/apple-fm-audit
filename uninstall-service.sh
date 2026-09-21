#!/bin/sh
set -eu
UID_NUM="$(id -u)"
GUI="gui/${UID_NUM}"
AGENTS="${HOME}/Library/LaunchAgents"

for label in \
  org.apple-fm-audit.proxy \
  org.apple-fm-audit.fm-serve \
  com.roy.apple-fm-audit \
  com.roy.fm-serve
do
  launchctl bootout "${GUI}/${label}" 2>/dev/null || true
  launchctl disable "${GUI}/${label}" 2>/dev/null || true
  rm -f "${AGENTS}/${label}.plist"
  echo "removed ${label}"
done
