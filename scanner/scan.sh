#!/bin/zsh
set -eu

readonly DEFAULT_QUEUE="Canon_G3010"
readonly DEFAULT_SERVICE_NAME="Canon G3010 series"
readonly DEFAULT_SERVICE_TYPE="_printer._tcp"
readonly DEVICE_NAME="airscan:w0:Canon G3010 WSD"

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
support_dir="${HOME}/Library/Application Support/Canon G3010 macOS Compat"
installed_runtime="${support_dir}/scanner-native"
system_runtime="/usr/local/libexec/canon-g3010-macos-compat/scanner-native"
source_runtime="${repo_root}/build/native-runtime"

printer_ip=""
queue_name="${DEFAULT_QUEUE}"
output_path="${PWD}/canon-g3010-scan-$(/bin/date '+%Y%m%d-%H%M%S').jpg"
resolution="300"
scan_mode="color"
paper="a4"
format="jpeg"
action="scan"
temporary_dir=""

usage() {
  cat <<'EOF'
Canon G3010 native macOS network scanner (WSD/SANE)

Usage:
  canon-g3010-scan [options]

Options:
  --ip ADDRESS       Printer IPv4 address. If omitted, use the installed
                     CUPS queue or DNS-SD service discovery.
  --queue NAME       CUPS queue used for address discovery
                     (default: Canon_G3010).
  --output FILE      Destination file (default: timestamped JPEG).
  --resolution DPI   150, 300, or 600 (default: 300).
  --mode MODE        color or gray (default: color).
  --paper SIZE       a4, letter, or full (default: a4).
  --format FORMAT    jpeg, png, or tiff (default: jpeg).
  --list             Detect the scanner without scanning.
  --build             Build the native runtime from pinned source versions.
  -h, --help         Show this help.

Docker is not required.
EOF
}

fail() {
  print -u2 -- "Error: $*"
  exit 1
}

info() {
  print -- "==> $*"
}

cleanup() {
  if [[ -n "${temporary_dir}" ]]; then
    case "${temporary_dir}" in
      /private/tmp/canon-g3010-scan.*|/tmp/canon-g3010-scan.*)
        /bin/rm -rf "${temporary_dir}"
        ;;
    esac
  fi
}
trap cleanup EXIT INT TERM

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

validate_safe_token() {
  local label="$1"
  local value="$2"
  [[ "${value}" =~ '^[A-Za-z0-9._-]+$' ]] ||
    fail "${label} contains unsupported characters: ${value}"
}

discover_queue_host() {
  /usr/bin/lpstat -v "${queue_name}" 2>/dev/null |
    /usr/bin/sed -nE \
      's#^.*: (lpd|ipp|ipps)://([^/:]+).*$#\2#p' |
    /usr/bin/head -n 1
}

discover_dnssd_host() {
  local lookup_file lookup_pid resolved_host i
  lookup_file="$(/usr/bin/mktemp -t canon-g3010-scan-dnssd)"

  /usr/bin/dns-sd \
    -L "${DEFAULT_SERVICE_NAME}" \
    "${DEFAULT_SERVICE_TYPE}" \
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

discover_printer_ip() {
  local host resolved
  host="$(discover_queue_host)"
  [[ -n "${host}" ]] || host="$(discover_dnssd_host)"
  [[ -n "${host}" ]] || return 1
  resolved="$(resolve_ipv4 "${host}")"
  validate_ipv4 "${resolved}" || return 1
  print -r -- "${resolved}"
}

select_runtime() {
  if [[ -x "${installed_runtime}/bin/scanimage" ]]; then
    print -r -- "${installed_runtime}"
  elif [[ -x "${system_runtime}/bin/scanimage" ]]; then
    print -r -- "${system_runtime}"
  elif [[ -x "${source_runtime}/bin/scanimage" ]]; then
    print -r -- "${source_runtime}"
  else
    return 1
  fi
}

write_config() {
  temporary_dir="$(/usr/bin/mktemp -d /private/tmp/canon-g3010-scan.XXXXXX)"
  {
    print -- "airscan"
  } >"${temporary_dir}/dll.conf"
  {
    print -- "[devices]"
    print -- "\"Canon G3010 WSD\" = http://${printer_ip}:80/wsd/scanservice.cgi, WSD"
    print -- ""
    print -- "[options]"
    print -- "discovery = disable"
    print -- "protocol = manual"
    print -- "model = hardware"
  } >"${temporary_dir}/airscan.conf"
}

while (( $# > 0 )); do
  case "$1" in
    --ip)
      (( $# >= 2 )) || fail "--ip requires a value"
      printer_ip="$2"
      shift 2
      ;;
    --queue)
      (( $# >= 2 )) || fail "--queue requires a value"
      queue_name="$2"
      shift 2
      ;;
    --output)
      (( $# >= 2 )) || fail "--output requires a value"
      output_path="$2"
      shift 2
      ;;
    --resolution)
      (( $# >= 2 )) || fail "--resolution requires a value"
      resolution="$2"
      shift 2
      ;;
    --mode)
      (( $# >= 2 )) || fail "--mode requires a value"
      scan_mode="${2:l}"
      shift 2
      ;;
    --paper)
      (( $# >= 2 )) || fail "--paper requires a value"
      paper="${2:l}"
      shift 2
      ;;
    --format)
      (( $# >= 2 )) || fail "--format requires a value"
      format="${2:l}"
      shift 2
      ;;
    --list)
      action="list"
      shift
      ;;
    --build)
      action="build"
      shift
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

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] ||
  fail "this scanner wrapper supports macOS only"

validate_safe_token "queue name" "${queue_name}"
[[ "${resolution}" == "150" || "${resolution}" == "300" ||
   "${resolution}" == "600" ]] ||
  fail "--resolution must be 150, 300, or 600"
[[ "${scan_mode}" == "color" || "${scan_mode}" == "gray" ]] ||
  fail "--mode must be color or gray"
[[ "${paper}" == "a4" || "${paper}" == "letter" || "${paper}" == "full" ]] ||
  fail "--paper must be a4, letter, or full"
[[ "${format}" == "jpeg" || "${format}" == "png" || "${format}" == "tiff" ]] ||
  fail "--format must be jpeg, png, or tiff"

if [[ "${action}" == "build" ]]; then
  build_script="${repo_root}/scanner/native/build-native.sh"
  [[ -x "${build_script}" ]] ||
    fail "native build script is unavailable in this installation"
  exec "${build_script}"
fi

runtime="$(select_runtime)" || fail "native scanner runtime is not installed"

if [[ -z "${printer_ip}" ]]; then
  printer_ip="$(discover_printer_ip)" ||
    fail "printer discovery failed; rerun with --ip ADDRESS"
fi
validate_ipv4 "${printer_ip}" || fail "invalid IPv4 address: ${printer_ip}"
write_config

if [[ "${action}" == "list" ]]; then
  info "Detecting Canon G3010 through native WSD"
  SANE_CONFIG_DIR="${temporary_dir}" \
  LD_LIBRARY_PATH="${runtime}/lib/sane" \
    "${runtime}/bin/scanimage" -L
  exit 0
fi

case "${paper}" in
  a4)
    width="210"
    height="297"
    ;;
  letter)
    width="215.9"
    height="279.4"
    ;;
  full)
    width="215.9"
    height="296.672"
    ;;
esac

case "${scan_mode}" in
  color) sane_mode="Color" ;;
  gray) sane_mode="Gray" ;;
esac

/bin/mkdir -p "${output_path:A:h}"
info "Scanning natively from ${printer_ip} at ${resolution} dpi"
SANE_CONFIG_DIR="${temporary_dir}" \
LD_LIBRARY_PATH="${runtime}/lib/sane" \
  "${runtime}/bin/scanimage" \
    -d "${DEVICE_NAME}" \
    --resolution "${resolution}" \
    --mode "${sane_mode}" \
    --format "${format}" \
    -x "${width}" \
    -y "${height}" \
    --output-file "${output_path:A}" \
    --progress

info "Saved ${output_path:A}"
