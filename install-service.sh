#!/bin/sh
# Install LaunchAgents so fm serve and apple-fm-audit start at login.
set -eu
cd "$(dirname "$0")"
ROOT="$PWD"
UID_NUM="$(id -u)"
GUI="gui/${UID_NUM}"
AGENTS="${HOME}/Library/LaunchAgents"
LOGS="${HOME}/Library/Logs"
UV="$(command -v uv)"
FM="$(command -v fm)"

if [ -z "${UV}" ]; then
  echo "uv is required. Install: https://docs.astral.sh/uv/" >&2
  exit 1
fi
if [ -z "${FM}" ]; then
  echo "fm is required (/usr/bin/fm on macOS 27)." >&2
  exit 1
fi

mkdir -p "${AGENTS}" "${LOGS}" "${ROOT}/data"
export PYTHONPATH="${ROOT}"
uv sync --frozen

write_plist() {
  label="$1"
  dest="${AGENTS}/${label}.plist"
  cat >"${dest}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${label}</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>WorkingDirectory</key>
	<string>${ROOT}</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>HOME</key>
		<string>${HOME}</string>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
		<key>PYTHONPATH</key>
		<string>${ROOT}</string>
		<key>AFM_LISTEN_HOST</key>
		<string>127.0.0.1</string>
		<key>AFM_LISTEN_PORT</key>
		<string>1977</string>
		<key>AFM_UPSTREAM</key>
		<string>127.0.0.1:1976</string>
		<key>AFM_DB</key>
		<string>${ROOT}/data/audit.sqlite</string>
		<key>AFM_FM_BIN</key>
		<string>${FM}</string>
	</dict>
	<key>ProgramArguments</key>
	<array>
$2
	</array>
	<key>StandardOutPath</key>
	<string>${LOGS}/${label}.log</string>
	<key>StandardErrorPath</key>
	<string>${LOGS}/${label}.log</string>
</dict>
</plist>
EOF
}

fm_args="		<string>${FM}</string>
		<string>serve</string>
		<string>--host</string>
		<string>127.0.0.1</string>
		<string>--port</string>
		<string>1976</string>"

audit_args="		<string>${UV}</string>
		<string>run</string>
		<string>--directory</string>
		<string>${ROOT}</string>
		<string>--frozen</string>
		<string>python</string>
		<string>-m</string>
		<string>apple_fm_audit</string>"

write_plist "com.roy.fm-serve" "${fm_args}"
write_plist "com.roy.apple-fm-audit" "${audit_args}"

for label in com.roy.fm-serve com.roy.apple-fm-audit; do
  launchctl bootout "${GUI}/${label}" 2>/dev/null || true
done

# Free the ports if a manual instance is still bound.
for port in 1976 1977; do
  pids="$(lsof -nP -iTCP:${port} -sTCP:LISTEN -t 2>/dev/null || true)"
  if [ -n "${pids}" ]; then
    echo "stopping listeners on ${port}: ${pids}"
    kill ${pids} 2>/dev/null || true
  fi
done
sleep 0.4

launchctl bootstrap "${GUI}" "${AGENTS}/com.roy.fm-serve.plist"
launchctl bootstrap "${GUI}" "${AGENTS}/com.roy.apple-fm-audit.plist"
launchctl enable "${GUI}/com.roy.fm-serve"
launchctl enable "${GUI}/com.roy.apple-fm-audit"

echo "installed"
echo "  com.roy.fm-serve        -> http://127.0.0.1:1976"
echo "  com.roy.apple-fm-audit  -> http://127.0.0.1:1977"
echo "logs: ${LOGS}/com.roy.fm-serve.log"
echo "      ${LOGS}/com.roy.apple-fm-audit.log"
echo "remove: ${ROOT}/uninstall-service.sh"
