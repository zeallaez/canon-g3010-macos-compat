#!/bin/zsh
set -eu

readonly BRIDGE_VERSION="1.2.0"
readonly IMAGE_NAME="canon-g3010-macos-compat-airscan:${BRIDGE_VERSION}"
readonly CONTAINER_NAME="canon-g3010-airscan-bridge"
readonly LABEL="io.github.zeallaez.canon-g3010-scanner-bridge"
readonly SERVICE_NAME="Canon G3010 Scanner"
readonly SERVICE_TYPE="_uscan._tcp"
readonly PROXY_HOST="canon-g3010-bridge.local."
readonly SERVICE_PORT="8090"
readonly SCANNER_UUID="7f2e31cb-c289-5757-b366-dde86d548b49"
readonly DEFAULT_QUEUE="Canon_G3010"
readonly DEFAULT_PRINTER_SERVICE="Canon G3010 series"

script_path="${0:A}"
script_dir="${script_path:h}"
runtime_dir="${script_dir}"
if [[ ! -f "${runtime_dir}/Dockerfile" ]]; then
  runtime_dir="/usr/local/libexec/canon-g3010-macos-compat/scanner-bridge"
fi

support_dir="${HOME}/Library/Application Support/Canon G3010 macOS Compat"
installed_runtime="${support_dir}/scanner-bridge"
launch_agents_dir="${HOME}/Library/LaunchAgents"
plist_path="${launch_agents_dir}/${LABEL}.plist"
log_dir="${HOME}/Library/Logs/Canon G3010 macOS Compat"

action="${1:-status}"
(( $# > 0 )) && shift
printer_ip=""

usage() {
  cat <<'EOF'
Canon G3010 macOS Image Capture bridge

Usage:
  ./scanner/bridge/bridge.sh COMMAND [--ip ADDRESS]

Commands:
  install     Install and start the per-user background bridge.
  start       Start an already installed bridge.
  stop        Stop the bridge and its private container.
  status      Show launch agent, container, and eSCL status.
  uninstall   Remove only the background bridge and its private files.
  run         Run in the foreground (used by launchd).

Options:
  --ip ADDRESS  Printer IPv4 address. If omitted, use the Canon_G3010
                print queue or local DNS-SD discovery.

After installation, open Apple's Image Capture and select
"Canon G3010 Scanner" under Shared.
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
  lookup_file="$(/usr/bin/mktemp -t canon-g3010-bridge-dnssd)"

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

docker_path() {
  if command -v docker >/dev/null 2>&1; then
    command -v docker
  elif [[ -x "/Applications/Docker.app/Contents/Resources/bin/docker" ]]; then
    print -r -- "/Applications/Docker.app/Contents/Resources/bin/docker"
  else
    return 1
  fi
}

wait_for_docker() {
  local docker_bin="$1"
  local i
  for i in {1..24}; do
    "${docker_bin}" info >/dev/null 2>&1 && return
    /bin/sleep 5
  done
  fail "Docker Desktop is installed but did not become ready"
}

write_runtime_config() {
  /bin/mkdir -p "${support_dir}/config" "${log_dir}"
  umask 077

  {
    print -- "[devices]"
    print -- "\"Canon G3010 WSD\" = http://${printer_ip}:80/wsd/scanservice.cgi, WSD"
    print -- ""
    print -- "[options]"
    print -- "discovery = disable"
    print -- "protocol = manual"
    print -- "model = hardware"
  } >"${support_dir}/config/airscan.conf"

  {
    print -- "# Keep sane-airscan enabled: this bridge intentionally exports it."
  } >"${support_dir}/config/ignore.conf"

  {
    print -- "# Empty access list: requests are accepted by the bridge."
    print -- "# The host publishes this service only on the local Bonjour network."
  } >"${support_dir}/config/access.conf"
}

build_image() {
  local docker_bin="$1"
  [[ -f "${runtime_dir}/Dockerfile" ]] ||
    fail "bridge runtime is missing: ${runtime_dir}/Dockerfile"
  [[ -f "${runtime_dir}/entrypoint.sh" ]] ||
    fail "bridge entrypoint is missing: ${runtime_dir}/entrypoint.sh"

  if ! "${docker_bin}" image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
    info "Building the open-source AirScan bridge (first run only)"
    "${docker_bin}" build --tag "${IMAGE_NAME}" "${runtime_dir}"
  fi
}

remove_container() {
  local docker_bin
  docker_bin="$(docker_path 2>/dev/null)" || return 0
  if "${docker_bin}" container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    "${docker_bin}" container rm --force "${CONTAINER_NAME}" >/dev/null
  fi
}

run_bridge() {
  local docker_bin i
  docker_bin="$(docker_path)" ||
    fail "Docker Desktop is required for the Image Capture bridge"
  wait_for_docker "${docker_bin}"

  write_runtime_config
  build_image "${docker_bin}"
  remove_container

  info "Starting eSCL bridge for ${printer_ip}"
  "${docker_bin}" run --detach \
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    --publish "127.0.0.1:${SERVICE_PORT}:${SERVICE_PORT}" \
    --mount \
      "type=bind,source=${support_dir}/config/airscan.conf,target=/etc/sane.d/airscan.conf,readonly" \
    --mount \
      "type=bind,source=${support_dir}/config/ignore.conf,target=/etc/airsane/ignore.conf,readonly" \
    --mount \
      "type=bind,source=${support_dir}/config/access.conf,target=/etc/airsane/access.conf,readonly" \
    "${IMAGE_NAME}" \
    --mdns-announce=true \
    --hotplug=false \
    --network-hotplug=false \
    --announce-base-url="http://127.0.0.1:${SERVICE_PORT}" \
    --access-log=- >/dev/null

  for i in {1..30}; do
    if /usr/bin/curl \
      --fail \
      --silent \
      --max-time 2 \
      "http://127.0.0.1:${SERVICE_PORT}/eSCL/ScannerCapabilities" \
      >/dev/null; then
      break
    fi
    /bin/sleep 1
  done

  /usr/bin/curl \
    --fail \
    --silent \
    --max-time 3 \
    "http://127.0.0.1:${SERVICE_PORT}/eSCL/ScannerCapabilities" \
    >/dev/null ||
    fail "the eSCL bridge did not become ready"

  info "Publishing ${SERVICE_NAME} to macOS Image Capture"
  exec /usr/bin/dns-sd \
    -P "${SERVICE_NAME}" "${SERVICE_TYPE}" local. "${SERVICE_PORT}" \
    "${PROXY_HOST}" "127.0.0.1" \
    "txtvers=1" \
    "vers=2.0" \
    "pdl=application/pdf,image/jpeg,image/png" \
    "ty=Canon G3010 Scanner" \
    "note=Local Mac bridge" \
    "uuid=${SCANNER_UUID}" \
    "rs=eSCL" \
    "cs=grayscale,color" \
    "is=platen" \
    "duplex=F"
}

install_bridge() {
  local source_runtime uid
  [[ "$(/usr/bin/uname -s)" == "Darwin" ]] ||
    fail "this bridge supports macOS only"
  [[ "${EUID}" -ne 0 ]] ||
    fail "run the bridge installer as the signed-in Mac user, not with sudo"

  if [[ -z "${printer_ip}" ]]; then
    info "Discovering the Canon G3010 scanner"
    printer_ip="$(discover_printer_ip)" ||
      fail "printer discovery failed; rerun with --ip ADDRESS"
  fi
  validate_ipv4 "${printer_ip}" || fail "invalid printer IPv4 address"

  source_runtime="${runtime_dir}"
  [[ -f "${source_runtime}/Dockerfile" ]] ||
    fail "bridge runtime is missing: ${source_runtime}/Dockerfile"

  /bin/mkdir -p "${installed_runtime}" "${launch_agents_dir}" "${log_dir}"
  /bin/cp -X "${script_path}" "${installed_runtime}/bridge.sh"
  /bin/cp -X "${source_runtime}/Dockerfile" "${installed_runtime}/Dockerfile"
  /bin/cp -X "${source_runtime}/entrypoint.sh" "${installed_runtime}/entrypoint.sh"
  /bin/chmod 0755 \
    "${installed_runtime}/bridge.sh" \
    "${installed_runtime}/entrypoint.sh"

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
    print -- "    <string>${installed_runtime}/bridge.sh</string>"
    print -- '    <string>run</string>'
    print -- '    <string>--ip</string>'
    print -- "    <string>${printer_ip}</string>"
    print -- '  </array>'
    print -- '  <key>RunAtLoad</key><true/>'
    print -- '  <key>KeepAlive</key><true/>'
    print -- '  <key>ProcessType</key><string>Background</string>'
    print -- '  <key>EnvironmentVariables</key>'
    print -- '  <dict>'
    print -- '    <key>PATH</key>'
    print -- '    <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>'
    print -- '  </dict>'
    print -- '  <key>StandardOutPath</key>'
    print -- "  <string>${log_dir}/bridge.log</string>"
    print -- '  <key>StandardErrorPath</key>'
    print -- "  <string>${log_dir}/bridge-error.log</string>"
    print -- '</dict>'
    print -- '</plist>'
  } >"${plist_path}"

  /usr/bin/plutil -lint "${plist_path}" >/dev/null
  uid="${UID}"
  /bin/launchctl bootout "gui/${uid}" "${plist_path}" >/dev/null 2>&1 || true
  /bin/launchctl bootstrap "gui/${uid}" "${plist_path}"
  /bin/launchctl kickstart -k "gui/${uid}/${LABEL}" >/dev/null

  info "Background bridge installed for printer ${printer_ip}"
  info "Open Image Capture and choose '${SERVICE_NAME}' under Shared"
}

start_bridge() {
  [[ -f "${plist_path}" ]] ||
    fail "bridge is not installed; run: $0 install --ip ADDRESS"
  /bin/launchctl bootout "gui/${UID}" "${plist_path}" >/dev/null 2>&1 || true
  /bin/launchctl bootstrap "gui/${UID}" "${plist_path}"
  /bin/launchctl kickstart -k "gui/${UID}/${LABEL}" >/dev/null
  info "Bridge start requested"
}

stop_bridge() {
  if [[ -f "${plist_path}" ]]; then
    /bin/launchctl bootout "gui/${UID}" "${plist_path}" >/dev/null 2>&1 || true
  fi
  remove_container
  info "Bridge stopped"
}

show_status() {
  local docker_bin
  if /bin/launchctl print "gui/${UID}/${LABEL}" >/dev/null 2>&1; then
    print -- "Launch agent: running"
  elif [[ -f "${plist_path}" ]]; then
    print -- "Launch agent: installed, not running"
  else
    print -- "Launch agent: not installed"
  fi

  docker_bin="$(docker_path 2>/dev/null)" || {
    print -- "Docker Desktop: not installed"
    return
  }
  if ! "${docker_bin}" info >/dev/null 2>&1; then
    print -- "Docker Desktop: not running"
    return
  fi
  if "${docker_bin}" container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    print -- "Bridge container: $(
      "${docker_bin}" inspect \
        --format '{{.State.Status}}' \
        "${CONTAINER_NAME}"
    )"
  else
    print -- "Bridge container: not created"
  fi
  if /usr/bin/curl \
    --fail \
    --silent \
    --max-time 2 \
    "http://127.0.0.1:${SERVICE_PORT}/eSCL/ScannerCapabilities" \
    >/dev/null; then
    print -- "macOS eSCL endpoint: ready"
  else
    print -- "macOS eSCL endpoint: unavailable"
  fi
}

uninstall_bridge() {
  stop_bridge
  /bin/rm -f "${plist_path}"
  case "${support_dir}" in
    "${HOME}/Library/Application Support/Canon G3010 macOS Compat")
      /bin/rm -rf "${support_dir}"
      ;;
    *)
      fail "refusing to remove unexpected support directory"
      ;;
  esac
  info "Background scanner bridge removed"
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

case "${action}" in
  install) install_bridge ;;
  start) start_bridge ;;
  stop) stop_bridge ;;
  status) show_status ;;
  uninstall) uninstall_bridge ;;
  run)
    validate_ipv4 "${printer_ip}" || fail "run requires --ip ADDRESS"
    run_bridge
    ;;
  -h|--help|help) usage ;;
  *) fail "unknown command: ${action}" ;;
esac
