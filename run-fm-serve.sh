#!/bin/sh
set -eu

export PATH="/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

if [ -n "${AFM_UPSTREAM:-}" ]; then
  HOST="${AFM_UPSTREAM%%:*}"
  PORT="${AFM_UPSTREAM##*:}"
else
  HOST="${AFM_UPSTREAM_HOST:-127.0.0.1}"
  PORT="${AFM_UPSTREAM_PORT:-1976}"
fi
FM="${AFM_FM_BIN:-/usr/bin/fm}"

get_pid() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN -t 2>/dev/null | head -n 1
  elif [ -x /usr/sbin/lsof ]; then
    /usr/sbin/lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN -t 2>/dev/null | head -n 1
  fi
}

PID="$(get_pid || true)"
WIN_ID=""

if [ -z "${PID}" ]; then
  WIN_ID="$(osascript -e '
  on run argv
    set fmCmd to item 1 of argv
    set hostArg to item 2 of argv
    set portArg to item 3 of argv
    tell application "Terminal"
      try
        close (every window whose busy of selected tab is false) saving no
      end try
      set newTab to do script "exec \"" & fmCmd & "\" serve --host " & hostArg & " --port " & portArg
      set w to first window whose tabs contains newTab
      set visible of w to false
      return (id of w as string)
    end tell
  end run' "${FM}" "${HOST}" "${PORT}" 2>/dev/null || true)"

  for _ in $(seq 1 50); do
    PID="$(get_pid || true)"
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
  if [ -n "${PID:-}" ]; then
    kill "${PID}" 2>/dev/null || true
  fi
  if [ -n "${WIN_ID:-}" ]; then
    osascript -e "tell application \"Terminal\" to try
      close (window id ${WIN_ID}) saving no
    end try" 2>/dev/null || true
  fi
  exit 0
}

trap cleanup TERM INT HUP EXIT

while [ -n "$(get_pid || true)" ]; do
  sleep 2 &
  wait $! 2>/dev/null || true
done
