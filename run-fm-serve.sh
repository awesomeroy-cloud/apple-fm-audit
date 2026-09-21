#!/bin/sh
set -eu

if [ -n "${AFM_UPSTREAM:-}" ]; then
  HOST="${AFM_UPSTREAM%%:*}"
  PORT="${AFM_UPSTREAM##*:}"
else
  HOST="${AFM_UPSTREAM_HOST:-127.0.0.1}"
  PORT="${AFM_UPSTREAM_PORT:-1976}"
fi
FM="${AFM_FM_BIN:-/usr/bin/fm}"

PID="$(lsof -nP -iTCP:${PORT} -sTCP:LISTEN -t 2>/dev/null || true)"

if [ -z "${PID}" ]; then
  osascript -e '
  on run argv
    set fmCmd to item 1 of argv
    set hostArg to item 2 of argv
    set portArg to item 3 of argv
    tell application "Terminal"
      set newTab to do script "exec \"" & fmCmd & "\" serve --host " & hostArg & " --port " & portArg
      set w to first window whose tabs contains newTab
      set visible of w to false
    end tell
  end run' "${FM}" "${HOST}" "${PORT}" >/dev/null

  for _ in $(seq 1 50); do
    PID="$(lsof -nP -iTCP:${PORT} -sTCP:LISTEN -t 2>/dev/null || true)"
    if [ -n "${PID}" ]; then
      break
    fi
    sleep 0.2
  done
fi

if [ -z "${PID}" ]; then
  echo "Failed to start fm serve on ${HOST}:${PORT}" >&2
  exit 1
fi

echo "fm serve running (PID: ${PID}) on ${HOST}:${PORT}"

cleanup() {
  kill "${PID}" 2>/dev/null || true
  exit 0
}

trap cleanup TERM INT HUP EXIT

while kill -0 "${PID}" 2>/dev/null; do
  sleep 2 &
  wait $! 2>/dev/null || true
done
