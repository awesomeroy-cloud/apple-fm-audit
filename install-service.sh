#!/bin/sh
# Install LaunchAgents so fm serve and apple-fm-audit start at login.
# ./install-service.sh        loopback only
# ./install-service.sh --lan  audit UI/API on 0.0.0.0:1977 (fm serve stays on 127.0.0.1)
set -eu
cd "$(dirname "$0")"
ROOT="$PWD"
LISTEN_HOST="127.0.0.1"
LABEL_FM="org.apple-fm-audit.fm-serve"
LABEL_AUDIT="org.apple-fm-audit.proxy"
for arg in "$@"; do
  case "$arg" in
    --lan) LISTEN_HOST="0.0.0.0" ;;
    -h|--help)
      echo "usage: $0 [--lan]"
      exit 0
      ;;
  esac
done
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
		<string>/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
		<key>PYTHONPATH</key>
		<string>${ROOT}</string>
		<key>AFM_LISTEN_HOST</key>
		<string>${LISTEN_HOST}</string>
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

fm_args="		<string>/bin/sh</string>
		<string>${ROOT}/run-fm-serve.sh</string>"

audit_args="		<string>${UV}</string>
		<string>run</string>
		<string>--directory</string>
		<string>${ROOT}</string>
		<string>--frozen</string>
		<string>python</string>
		<string>-m</string>
		<string>apple_fm_audit</string>"

write_plist "${LABEL_FM}" "${fm_args}"
write_plist "${LABEL_AUDIT}" "${audit_args}"

for label in "${LABEL_FM}" "${LABEL_AUDIT}"; do
  launchctl bootout "${GUI}/${label}" 2>/dev/null || true
done
for label in com.roy.fm-serve com.roy.apple-fm-audit; do
  launchctl bootout "${GUI}/${label}" 2>/dev/null || true
  rm -f "${AGENTS}/${label}.plist"
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

launchctl bootstrap "${GUI}" "${AGENTS}/${LABEL_FM}.plist"
launchctl bootstrap "${GUI}" "${AGENTS}/${LABEL_AUDIT}.plist"
launchctl enable "${GUI}/${LABEL_FM}"
launchctl enable "${GUI}/${LABEL_AUDIT}"

echo "installed"
echo "  ${LABEL_FM}     -> http://127.0.0.1:1976  (loopback)"
if [ "${LISTEN_HOST}" = "0.0.0.0" ]; then
  echo "  ${LABEL_AUDIT}        -> 0.0.0.0:1977"
  echo "  other devices: http://<this-mac-lan-ip>:1977/v1"
  echo "  anyone on this network can use the model and open the audit page"
else
  echo "  ${LABEL_AUDIT}        -> http://127.0.0.1:1977"
  echo "  LAN: re-run $0 --lan"
fi
echo "logs: ${LOGS}/${LABEL_FM}.log"
echo "      ${LOGS}/${LABEL_AUDIT}.log"
echo "remove: ${ROOT}/uninstall-service.sh"
