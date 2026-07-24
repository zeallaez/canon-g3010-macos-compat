#!/bin/zsh
set -eu

readonly BRIDGE_VERSION="1.3.0"
readonly LABEL="io.github.zeallaez.canon-g3010-scanner-bridge"
readonly SERVICE_NAME="Canon G3010 Scanner"
readonly SERVICE_TYPE="_uscan._tcp"
readonly PROXY_HOST="canon-g3010-bridge.local."
readonly SERVICE_PORT="8090"
readonly SCANNER_UUID="7f2e31cb-c289-5757-b366-dde86d548b49"
readonly DEFAULT_QUEUE="Canon_G3010"
readonly DEFAULT_PRINTER_SERVICE="Canon G3010 series"
readonly LEGACY_CONTAINER="canon-g3010-airscan-bridge"

script_path="${0:A}"
script_dir="${script_path:h}"
support_dir="${HOME}/Library/Application Support/Canon G3010 macOS Compat"
installed_bridge="${support_dir}/scanner-bridge/bridge.sh"
installed_runtime="${support_dir}/scanner-native"
system_runtime="/usr/local/libexec/canon-g3010-macos-compat/scanner-native"
source_runtime="${script_dir:h:h}/build/native-runtime"
launch_agents_dir="${HOME}/Library/LaunchAgents"
plist_path="${launch_agents_dir}/${LABEL}.plist"
log_dir="${HOME}/Library/Logs/Canon G3010 macOS Compat"

action="${1:-status}"
(( $# > 0 )) && shift
printer_ip=""
engine_pid=""
bonjour_pid=""

usage() {
  cat <<'EOF'
Canon G3010 native macOS Image Capture bridge

Usage:
  canon-g3010-scanner-bridge COMMAND [--ip ADDRESS]

Commands:
  install     Install and start the per-user native background bridge.
  start       Start an already installed bridge.
  stop        Stop the bridge.
  status      Show launch agent and eSCL status.
  uninstall   Remove the bridge and its private files.
  run         Run in the foreground (used by launchd).

Options:
  --ip ADDRESS  Printer IPv4 address. If omitted, use the Canon_G3010
                print queue or local DNS-SD discovery.

Docker is not required. After installation, open Apple's Image Capture
and select "Canon G3010 Scanner" under Shared.
EOF
}

fail() {
  print -u2 -- "Error: $*"
  exit 1
}

info() {
  print -- "==> $*"
}

validate_ipv4() {
  local value="$1"
  local octet
  typeset -a octets

  [[ "${value}" =~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' ]] || return 1
  octets=("${(@s:.:)value}")
  for octet in "${octets[@]}"; do
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}

resolve_ipv4() {
  local host="$1"
  local resolved

  if validate_ipv4 "${host}"; then
    print -r -- "${host}"
    return
  fi

  resolved="$(
    /usr/bin/dscacheutil -q host -a name "${host%.}" 2>/dev/null |
      /usr/bin/awk '/^ip_address: / && $2 !~ /:/ { print $2; exit }'
  )"
  print -r -- "${resolved}"
}

discover_queue_host() {
  /usr/bin/lpstat -v "${DEFAULT_QUEUE}" 2>/dev/null |
    /usr/bin/sed -nE \
      's#^.*: (lpd|ipp|ipps)://([^/:]+).*$#\2#p' |
    /usr/bin/head -n 1
}

discover_dnssd_host() {
  local lookup_file lookup_pid resolved_host i
  lookup_file="$(/usr/bin/mktemp -t canon-g3010-native-dnssd)"

  /usr/bin/dns-sd \
    -L "${DEFAULT_PRINTER_SERVICE}" \
    "_printer._tcp" \
    local. >"${lookup_file}" 2>&1 &
  lookup_pid=$!

  for i in {1..10}; do
    /usr/bin/grep -q "can be reached at" "${lookup_file}" && break
    /bin/sleep 1
  done

  /bin/kill "${lookup_pid}" 2>/dev/null || true
  wait "${lookup_pid}" 2>/dev/null || true
  resolved_host="$(
    /usr/bin/sed -nE \
      's/.* can be reached at ([^: ]+):[0-9]+.*/\1/p' \
      "${lookup_file}" |
      /usr/bin/head -n 1
  )"
  /bin/rm -f "${lookup_file}"
  print -r -- "${resolved_host}"
}

discover_printer_ip() {
  local host resolved
  host="$(discover_queue_host)"
  if [[ -z "${host}" ]]; then
    info "The print queue was not found; trying DNS-SD discovery" >&2
    host="$(discover_dnssd_host)"
  fi
  [[ -n "${host}" ]] || return 1
  resolved="$(resolve_ipv4 "${host}")"
  validate_ipv4 "${resolved}" || return 1
  print -r -- "${resolved}"
}

select_runtime() {
  if [[ -x "${installed_runtime}/bin/airsaned" ]]; then
    print -r -- "${installed_runtime}"
  elif [[ -x "${system_runtime}/bin/airsaned" ]]; then
    print -r -- "${system_runtime}"
  elif [[ -x "${source_runtime}/bin/airsaned" ]]; then
    print -r -- "${source_runtime}"
  else
    return 1
  fi
}

check_runtime() {
  local runtime="$1"
  [[ -x "${runtime}/bin/airsaned" ]] ||
    fail "native AirSane runtime is missing: ${runtime}/bin/airsaned"
  [[ -x "${runtime}/bin/scanimage" ]] ||
    fail "native scanimage runtime is missing: ${runtime}/bin/scanimage"
  [[ -f "${runtime}/lib/sane/libsane-airscan.1.so" ]] ||
    fail "native WSD backend is missing: ${runtime}/lib/sane/libsane-airscan.1.so"
}

write_runtime_config() {
  local sane_dir="${support_dir}/config/sane.d"
  local airsane_dir="${support_dir}/config/airsane"

  /bin/mkdir -p "${sane_dir}" "${airsane_dir}" "${log_dir}"
  umask 077

  {
    print -- "airscan"
  } >"${sane_dir}/dll.conf"

  {
    print -- "[devices]"
    print -- "\"Canon G3010 WSD\" = http://${printer_ip}:80/wsd/scanservice.cgi, WSD"
    print -- ""
    print -- "[options]"
    print -- "discovery = disable"
    print -- "protocol = manual"
    print -- "model = hardware"
  } >"${sane_dir}/airscan.conf"

  {
    print -- "allow 127.0.0.1"
    print -- "allow ::1"
  } >"${airsane_dir}/access.conf"

  {
    print -- "# Keep the configured airscan backend enabled."
  } >"${airsane_dir}/ignore.conf"

  {
    print -- "location Local Mac bridge"
  } >"${airsane_dir}/options.conf"
}

cleanup_legacy_container() {
  local docker_bin=""
  if command -v docker >/dev/null 2>&1; then
    docker_bin="$(command -v docker)"
  elif [[ -x "/Applications/Docker.app/Contents/Resources/bin/docker" ]]; then
    docker_bin="/Applications/Docker.app/Contents/Resources/bin/docker"
  fi

  if [[ -n "${docker_bin}" ]] &&
     "${docker_bin}" container inspect "${LEGACY_CONTAINER}" >/dev/null 2>&1; then
    info "Removing the superseded private Docker bridge"
    "${docker_bin}" container rm --force "${LEGACY_CONTAINER}" >/dev/null ||
      true
  fi
}

stop_children() {
  trap - EXIT INT TERM
  [[ -n "${bonjour_pid}" ]] &&
    /bin/kill "${bonjour_pid}" 2>/dev/null || true
  [[ -n "${engine_pid}" ]] &&
    /bin/kill "${engine_pid}" 2>/dev/null || true
  [[ -n "${bonjour_pid}" ]] && wait "${bonjour_pid}" 2>/dev/null || true
  [[ -n "${engine_pid}" ]] && wait "${engine_pid}" 2>/dev/null || true
}

run_bridge() {
  local runtime="$1"
  local sane_dir="${support_dir}/config/sane.d"
  local airsane_dir="${support_dir}/config/airsane"
  local i

  check_runtime "${runtime}"
  trap stop_children EXIT INT TERM

  info "Starting native eSCL bridge for ${printer_ip}"
  SANE_CONFIG_DIR="${sane_dir}" \
  LD_LIBRARY_PATH="${runtime}/lib/sane" \
    "${runtime}/bin/airsaned" \
      --listen-port="${SERVICE_PORT}" \
      --interface=lo0 \
      --mdns-announce=false \
      --announce-base-url="http://127.0.0.1:${SERVICE_PORT}" \
      --hotplug=false \
      --network-hotplug=false \
      --disclose-version=false \
      --options-file="${airsane_dir}/options.conf" \
      --ignore-list="${airsane_dir}/ignore.conf" \
      --access-file="${airsane_dir}/access.conf" \
      >>"${log_dir}/native-engine.log" 2>&1 &
  engine_pid=$!

  for i in {1..60}; do
    if /usr/bin/curl --fail --silent --max-time 2 \
      "http://127.0.0.1:${SERVICE_PORT}/eSCL/ScannerCapabilities" \
      >/dev/null; then
      break
    fi
    /bin/kill -0 "${engine_pid}" 2>/dev/null ||
      fail "the native eSCL engine exited during startup"
    /bin/sleep 1
  done

  /usr/bin/curl --fail --silent --max-time 3 \
    "http://127.0.0.1:${SERVICE_PORT}/eSCL/ScannerCapabilities" \
    >/dev/null ||
    fail "the native eSCL bridge did not become ready"

  info "Publishing ${SERVICE_NAME} to macOS Image Capture"
  /usr/bin/dns-sd \
    -P "${SERVICE_NAME}" "${SERVICE_TYPE}" local. "${SERVICE_PORT}" \
    "${PROXY_HOST}" "127.0.0.1" \
    "txtvers=1" \
    "vers=2.0" \
    "pdl=application/pdf,image/jpeg,image/png" \
    "ty=Canon G3010 Scanner" \
    "note=Native macOS bridge" \
    "uuid=${SCANNER_UUID}" \
    "rs=eSCL" \
    "cs=grayscale,color" \
    "is=platen" \
    "duplex=F" &
  bonjour_pid=$!

  wait "${bonjour_pid}"
}

write_launch_agent() {
  /bin/mkdir -p "${launch_agents_dir}" "${log_dir}"
  umask 077

  {
    print -- '<?xml version="1.0" encoding="UTF-8"?>'
    print -- '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
    print -- '  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    print -- '<plist version="1.0">'
    print -- '<dict>'
    print -- '  <key>Label</key>'
    print -- "  <string>${LABEL}</string>"
    print -- '  <key>ProgramArguments</key>'
    print -- '  <array>'
    print -- "    <string>${installed_bridge}</string>"
    print -- '    <string>run</string>'
    print -- '    <string>--ip</string>'
    print -- "    <string>${printer_ip}</string>"
    print -- '  </array>'
    print -- '  <key>RunAtLoad</key>'
    print -- '  <true/>'
    print -- '  <key>KeepAlive</key>'
    print -- '  <true/>'
    print -- '  <key>ProcessType</key>'
    print -- '  <string>Background</string>'
    print -- '  <key>StandardOutPath</key>'
    print -- "  <string>${log_dir}/bridge.log</string>"
    print -- '  <key>StandardErrorPath</key>'
    print -- "  <string>${log_dir}/bridge-error.log</string>"
    print -- '</dict>'
    print -- '</plist>'
  } >"${plist_path}"

  /usr/bin/plutil -lint "${plist_path}" >/dev/null
}

install_bridge() {
  local runtime
  if [[ -x "${system_runtime}/bin/airsaned" ]]; then
    runtime="${system_runtime}"
  elif [[ -x "${source_runtime}/bin/airsaned" ]]; then
    runtime="${source_runtime}"
  elif [[ -x "${installed_runtime}/bin/airsaned" ]]; then
    runtime="${installed_runtime}"
  else
    fail "native runtime is not built or installed"
  fi
  check_runtime "${runtime}"

  if [[ -z "${printer_ip}" ]]; then
    printer_ip="$(discover_printer_ip)" ||
      fail "printer discovery failed; rerun with --ip ADDRESS"
  fi

  /bin/launchctl bootout "gui/$(/usr/bin/id -u)" "${plist_path}" \
    >/dev/null 2>&1 || true
  cleanup_legacy_container

  info "Installing native runtime ${BRIDGE_VERSION}"
  /bin/mkdir -p "${installed_bridge:h}"
  if [[ "${runtime}" != "${installed_runtime}" ]]; then
    /bin/rm -rf "${installed_runtime}"
    /bin/cp -R -X "${runtime}" "${installed_runtime}"
  fi
  /bin/cp -X "${script_path}" "${installed_bridge}"
  /bin/chmod 0755 "${installed_bridge}" \
    "${installed_runtime}/bin/airsaned" \
    "${installed_runtime}/bin/scanimage"

  write_runtime_config
  write_launch_agent

  /bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "${plist_path}"

  for _ in {1..60}; do
    /usr/bin/curl --fail --silent --max-time 2 \
      "http://127.0.0.1:${SERVICE_PORT}/eSCL/ScannerCapabilities" \
      >/dev/null && break
    /bin/sleep 1
  done

  /usr/bin/curl --fail --silent --max-time 3 \
    "http://127.0.0.1:${SERVICE_PORT}/eSCL/ScannerCapabilities" \
    >/dev/null ||
    fail "the installed native bridge did not become ready"

  info "Native scanner bridge installed; Docker is not used"
}

start_bridge() {
  [[ -f "${plist_path}" ]] || fail "bridge is not installed"
  /bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "${plist_path}" \
    >/dev/null 2>&1 || true
  /bin/launchctl kickstart -k "gui/$(/usr/bin/id -u)/${LABEL}"
  info "Native scanner bridge started"
}

stop_bridge() {
  /bin/launchctl bootout "gui/$(/usr/bin/id -u)" "${plist_path}" \
    >/dev/null 2>&1 || true
  cleanup_legacy_container
  info "Scanner bridge stopped"
}

status_bridge() {
  local launch_status="stopped"
  local endpoint_status="unreachable"

  if /bin/launchctl print "gui/$(/usr/bin/id -u)/${LABEL}" \
    >/dev/null 2>&1; then
    launch_status="running"
  fi
  if /usr/bin/curl --fail --silent --max-time 2 \
    "http://127.0.0.1:${SERVICE_PORT}/eSCL/ScannerStatus" \
    >/dev/null; then
    endpoint_status="ready"
  fi

  print -- "Bridge version: ${BRIDGE_VERSION}"
  print -- "Runtime: native macOS (no Docker)"
  print -- "LaunchAgent: ${launch_status}"
  print -- "eSCL endpoint: ${endpoint_status}"
  print -- "Endpoint: http://127.0.0.1:${SERVICE_PORT}/eSCL"
}

uninstall_bridge() {
  stop_bridge
  /bin/rm -f "${plist_path}"
  /bin/rm -rf \
    "${support_dir}/scanner-bridge" \
    "${support_dir}/scanner-native" \
    "${support_dir}/config"
  info "Native scanner bridge removed"
}

while (( $# > 0 )); do
  case "$1" in
    --ip)
      (( $# >= 2 )) || fail "--ip requires a value"
      printer_ip="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

if [[ -n "${printer_ip}" ]]; then
  validate_ipv4 "${printer_ip}" || fail "invalid IPv4 address: ${printer_ip}"
fi

case "${action}" in
  install)
    install_bridge
    ;;
  start)
    start_bridge
    ;;
  stop)
    stop_bridge
    ;;
  status)
    status_bridge
    ;;
  uninstall)
    uninstall_bridge
    ;;
  run)
    [[ -n "${printer_ip}" ]] || fail "run requires --ip ADDRESS"
    runtime="$(select_runtime)" || fail "native runtime is missing"
    run_bridge "${runtime}"
    ;;
  -h|--help)
    usage
    ;;
  *)
    fail "unknown command: ${action}"
    ;;
esac
