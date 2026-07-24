#!/bin/zsh
set -eu

readonly BRIDGE_VERSION="1.4.0"
readonly LABEL="io.github.zeallaez.canon-g3010-scanner-bridge"
readonly SERVICE_NAME="Canon G3010 series"
readonly SERVICE_TYPE="_uscan._tcp"
readonly PROXY_HOST="canon-g3010-bridge.local."
readonly SERVICE_PORT="8090"
readonly FALLBACK_UUID="7f2e31cb-c289-5757-b366-dde86d548b49"
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
settings_path="${support_dir}/config/bridge.conf"

action="${1:-status}"
(( $# > 0 )) && shift
cli_printer_ip=""
printer_ip=""
preferred_ip=""
printer_host=""
printer_uuid="${FALLBACK_UUID}"
engine_pid=""
bonjour_pid=""
shutting_down="no"
engine_kind="unknown"

usage() {
  cat <<'EOF'
Canon G3010 native macOS multifunction scanner bridge

Usage:
  canon-g3010-scanner-bridge COMMAND [--ip ADDRESS]

Commands:
  install     Install and start the per-user native background bridge.
  start       Start an already installed bridge.
  stop        Stop the bridge.
  status      Show identity, address, launch agent, and eSCL status.
  uninstall   Remove the bridge and its private files.
  run         Run the auto-reconnecting supervisor (used by launchd).

Options:
  --ip ADDRESS  Initial/fallback printer IPv4 address. The bridge still tracks
                the printer's stable Bonjour hostname when it is available.

The scanner uses the printer's real Bonjour UUID, so macOS can associate
printing and scanning with the same multifunction device. Docker is not used.
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

validate_hostname() {
  [[ "$1" =~ '^[A-Za-z0-9._-]+$' ]]
}

validate_uuid() {
  [[ "$1" =~ '^[A-Fa-f0-9-]{32,36}$' ]]
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

probe_wsd() {
  local address="$1"
  validate_ipv4 "${address}" || return 1
  /usr/bin/curl --silent --show-error \
    --connect-timeout 2 --max-time 4 \
    --output /dev/null \
    "http://${address}:80/wsd/scanservice.cgi"
}

discover_queue_host() {
  /usr/bin/lpstat -v "${DEFAULT_QUEUE}" 2>/dev/null |
    /usr/bin/sed -nE \
      's#^.*: (lpd|ipp|ipps)://([^/:]+).*$#\2#p' |
    /usr/bin/head -n 1
}

discover_dnssd_record() {
  local lookup_file lookup_pid i host uuid address
  lookup_file="$(/usr/bin/mktemp -t canon-g3010-identity)"

  /usr/bin/dns-sd \
    -L "${DEFAULT_PRINTER_SERVICE}" \
    "_printer._tcp" \
    local. >"${lookup_file}" 2>&1 &
  lookup_pid=$!

  for i in {1..10}; do
    /usr/bin/grep -q "can be reached at" "${lookup_file}" &&
      /usr/bin/grep -q "UUID=" "${lookup_file}" &&
      break
    /bin/sleep 1
  done

  /bin/kill "${lookup_pid}" 2>/dev/null || true
  wait "${lookup_pid}" 2>/dev/null || true
  host="$(
    /usr/bin/sed -nE \
      's/.* can be reached at ([^: ]+):[0-9]+.*/\1/p' \
      "${lookup_file}" |
      /usr/bin/head -n 1
  )"
  uuid="$(
    /usr/bin/sed -nE 's/.*(^|[[:space:]])UUID=([^[:space:]]+).*/\2/p' \
      "${lookup_file}" |
      /usr/bin/head -n 1
  )"
  /bin/rm -f "${lookup_file}"

  [[ -n "${host}" ]] || return 1
  validate_hostname "${host}" || return 1
  address="$(resolve_ipv4 "${host}")"
  validate_ipv4 "${address}" || return 1

  printer_host="${host}"
  printer_ip="${address}"
  if validate_uuid "${uuid}"; then
    printer_uuid="${uuid}"
  fi
}

load_settings() {
  local key value
  [[ -f "${settings_path}" ]] || return 0

  while IFS='=' read -r key value; do
    case "${key}" in
      preferred_ip)
        validate_ipv4 "${value}" && preferred_ip="${value}"
        ;;
      printer_host)
        validate_hostname "${value}" && printer_host="${value}"
        ;;
      printer_uuid)
        validate_uuid "${value}" && printer_uuid="${value}"
        ;;
    esac
  done <"${settings_path}"
}

write_settings() {
  /bin/mkdir -p "${settings_path:h}"
  umask 077
  {
    print -- "preferred_ip=${preferred_ip}"
    print -- "printer_host=${printer_host}"
    print -- "printer_uuid=${printer_uuid}"
  } >"${settings_path}"
}

refresh_identity() {
  local requested_ip="${printer_ip}"
  if discover_dnssd_record; then
    preferred_ip="${printer_ip}"
    return 0
  fi

  if [[ -n "${printer_host}" ]]; then
    printer_ip="$(resolve_ipv4 "${printer_host}")"
    if validate_ipv4 "${printer_ip}"; then
      preferred_ip="${printer_ip}"
      return 0
    fi
  fi

  if [[ -z "${requested_ip}" ]]; then
    local queue_host
    queue_host="$(discover_queue_host)"
    if [[ -n "${queue_host}" ]]; then
      printer_host="${queue_host}"
      printer_ip="$(resolve_ipv4 "${queue_host}")"
    fi
  else
    printer_ip="${requested_ip}"
  fi

  if ! validate_ipv4 "${printer_ip}"; then
    printer_ip="${preferred_ip}"
  fi
  validate_ipv4 "${printer_ip}" || return 1
  preferred_ip="${printer_ip}"
}

resolve_current_ip() {
  local resolved=""
  if [[ -n "${printer_host}" ]]; then
    resolved="$(resolve_ipv4 "${printer_host}")"
    if validate_ipv4 "${resolved}" && probe_wsd "${resolved}"; then
      print -r -- "${resolved}"
      return 0
    fi
  fi

  printer_ip=""
  if discover_dnssd_record && probe_wsd "${printer_ip}"; then
    preferred_ip="${printer_ip}"
    write_settings
    print -r -- "${printer_ip}"
    return 0
  fi

  if validate_ipv4 "${preferred_ip}" && probe_wsd "${preferred_ip}"; then
    print -r -- "${preferred_ip}"
    return 0
  fi
  return 1
}

select_runtime() {
  local candidate
  for candidate in \
    "${installed_runtime}" \
    "${system_runtime}" \
    "${source_runtime}"; do
    if [[ -x "${candidate}/bin/canon-g3010-escl-bridge" ||
          -x "${candidate}/bin/airsaned" ]]; then
      print -r -- "${candidate}"
      return 0
    fi
  done
  return 1
}

check_runtime() {
  local runtime="$1"
  [[ -x "${runtime}/bin/canon-g3010-escl-bridge" ||
     -x "${runtime}/bin/airsaned" ]] ||
    fail "native eSCL runtime is missing from ${runtime}/bin"
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
  [[ -n "${bonjour_pid}" ]] &&
    /bin/kill "${bonjour_pid}" 2>/dev/null || true
  [[ -n "${engine_pid}" ]] &&
    /bin/kill "${engine_pid}" 2>/dev/null || true
  [[ -n "${bonjour_pid}" ]] && wait "${bonjour_pid}" 2>/dev/null || true
  [[ -n "${engine_pid}" ]] && wait "${engine_pid}" 2>/dev/null || true
  bonjour_pid=""
  engine_pid=""
}

shutdown_supervisor() {
  shutting_down="yes"
  stop_children
}

start_engine() {
  local runtime="$1"
  local sane_dir="${support_dir}/config/sane.d"
  local airsane_dir="${support_dir}/config/airsane"

  if [[ -x "${runtime}/bin/canon-g3010-escl-bridge" ]]; then
    engine_kind="direct WSD-to-eSCL"
    "${runtime}/bin/canon-g3010-escl-bridge" \
      --listen-port "${SERVICE_PORT}" \
      --runtime-dir "${runtime}" \
      --config-dir "${sane_dir}" \
      --printer-ip "${printer_ip}" \
      --uuid "${printer_uuid}" \
      --service-name "${SERVICE_NAME}" \
      >>"${log_dir}/native-engine.log" 2>&1 &
  else
    engine_kind="AirSane fallback"
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
  fi
  engine_pid=$!
}

wait_until_ready() {
  local i
  for i in {1..60}; do
    if /usr/bin/curl --fail --silent --max-time 2 \
      "http://127.0.0.1:${SERVICE_PORT}/eSCL/ScannerCapabilities" \
      >/dev/null; then
      return 0
    fi
    /bin/kill -0 "${engine_pid}" 2>/dev/null || return 1
    /bin/sleep 1
  done
  return 1
}

publish_scanner() {
  local admin_host="${printer_host:-${printer_ip}}"
  /usr/bin/dns-sd \
    -P "${SERVICE_NAME}" "${SERVICE_TYPE}" local. "${SERVICE_PORT}" \
    "${PROXY_HOST}" "127.0.0.1" \
    "txtvers=1" \
    "vers=2.0" \
    "pdl=image/jpeg,image/png" \
    "ty=${SERVICE_NAME}" \
    "product=(${SERVICE_NAME})" \
    "note=Native macOS multifunction bridge" \
    "adminurl=http://${admin_host}" \
    "UUID=${printer_uuid}" \
    "rs=eSCL" \
    "cs=grayscale,color" \
    "is=platen" \
    "duplex=F" \
    "Scan=T" &
  bonjour_pid=$!
}

run_session() {
  local runtime="$1"
  local candidate failures=0

  write_runtime_config
  start_engine "${runtime}"
  info "Starting ${engine_kind} bridge for ${printer_ip}"
  if ! wait_until_ready; then
    stop_children
    return 1
  fi

  info "Publishing ${SERVICE_NAME} with UUID ${printer_uuid}"
  publish_scanner

  while [[ "${shutting_down}" == "no" ]]; do
    /bin/sleep 15
    /bin/kill -0 "${engine_pid}" 2>/dev/null || return 1
    /bin/kill -0 "${bonjour_pid}" 2>/dev/null || return 1

    candidate="$(resolve_current_ip 2>/dev/null || true)"
    if validate_ipv4 "${candidate}"; then
      failures=0
      if [[ "${candidate}" != "${printer_ip}" ]]; then
        info "Printer address changed: ${printer_ip} -> ${candidate}"
        printer_ip="${candidate}"
        preferred_ip="${candidate}"
        write_settings
        return 2
      fi
    else
      (( failures += 1 ))
      if (( failures >= 3 )); then
        info "Printer is unavailable; rediscovering"
        return 3
      fi
    fi
  done
  return 0
}

run_supervisor() {
  local runtime candidate
  runtime="$(select_runtime)" || fail "native runtime is missing"
  check_runtime "${runtime}"
  load_settings
  if [[ -n "${cli_printer_ip}" ]]; then
    preferred_ip="${cli_printer_ip}"
  fi
  trap shutdown_supervisor EXIT INT TERM

  while [[ "${shutting_down}" == "no" ]]; do
    candidate="$(resolve_current_ip 2>/dev/null || true)"
    if ! validate_ipv4 "${candidate}"; then
      info "Printer not found; retrying discovery in 10 seconds"
      /bin/sleep 10
      continue
    fi
    printer_ip="${candidate}"
    preferred_ip="${candidate}"
    write_settings

    info "Using ${SERVICE_NAME} at ${printer_ip}"
    run_session "${runtime}" || true
    stop_children
    [[ "${shutting_down}" == "yes" ]] && break
    info "Restarting bridge after network or engine change"
    /bin/sleep 3
  done
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
  if [[ -x "${system_runtime}/bin/canon-g3010-escl-bridge" ]]; then
    runtime="${system_runtime}"
  elif [[ -x "${source_runtime}/bin/canon-g3010-escl-bridge" ]]; then
    runtime="${source_runtime}"
  elif [[ -x "${installed_runtime}/bin/canon-g3010-escl-bridge" ]]; then
    runtime="${installed_runtime}"
  else
    runtime="$(select_runtime)" || fail "native runtime is not built or installed"
  fi
  check_runtime "${runtime}"

  load_settings
  printer_ip="${cli_printer_ip}"
  refresh_identity ||
    fail "printer discovery failed; rerun with --ip ADDRESS"
  preferred_ip="${printer_ip}"
  probe_wsd "${printer_ip}" ||
    fail "the WSD scanner is not reachable at ${printer_ip}"

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
    "${installed_runtime}/bin/scanimage"
  [[ ! -f "${installed_runtime}/bin/canon-g3010-escl-bridge" ]] ||
    /bin/chmod 0755 "${installed_runtime}/bin/canon-g3010-escl-bridge"
  [[ ! -f "${installed_runtime}/bin/airsaned" ]] ||
    /bin/chmod 0755 "${installed_runtime}/bin/airsaned"

  write_settings
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

  info "Multifunction identity: ${printer_uuid}"
  info "Automatic IP reconnection: enabled"
  info "Direct WSD-to-eSCL bridge installed; Docker is not used"
}

start_bridge() {
  [[ -f "${plist_path}" ]] || fail "bridge is not installed"
  if /bin/launchctl print "gui/$(/usr/bin/id -u)/${LABEL}" \
    >/dev/null 2>&1; then
    /bin/launchctl kickstart -k "gui/$(/usr/bin/id -u)/${LABEL}"
  else
    /bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "${plist_path}"
  fi
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
  local current_ip=""
  local runtime=""

  load_settings
  current_ip="$(resolve_current_ip 2>/dev/null || true)"
  if /bin/launchctl print "gui/$(/usr/bin/id -u)/${LABEL}" \
    >/dev/null 2>&1; then
    launch_status="running"
  fi
  if /usr/bin/curl --fail --silent --max-time 2 \
    "http://127.0.0.1:${SERVICE_PORT}/eSCL/ScannerStatus" \
    >/dev/null; then
    endpoint_status="ready"
  fi
  runtime="$(select_runtime 2>/dev/null || true)"
  if [[ -x "${runtime}/bin/canon-g3010-escl-bridge" ]]; then
    engine_kind="direct WSD-to-eSCL"
  elif [[ -x "${runtime}/bin/airsaned" ]]; then
    engine_kind="AirSane fallback"
  fi

  print -- "Bridge version: ${BRIDGE_VERSION}"
  print -- "Engine: ${engine_kind}"
  print -- "Multifunction UUID: ${printer_uuid}"
  print -- "Bonjour hostname: ${printer_host:-unavailable}"
  print -- "Current printer IP: ${current_ip:-unavailable}"
  print -- "Automatic IP reconnection: enabled"
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

if [[ "${action}" == "-h" || "${action}" == "--help" ]]; then
  usage
  exit 0
fi

while (( $# > 0 )); do
  case "$1" in
    --ip)
      (( $# >= 2 )) || fail "--ip requires a value"
      cli_printer_ip="$2"
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

if [[ -n "${cli_printer_ip}" ]]; then
  validate_ipv4 "${cli_printer_ip}" ||
    fail "invalid IPv4 address: ${cli_printer_ip}"
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
    run_supervisor
    ;;
  *)
    fail "unknown command: ${action}"
    ;;
esac
