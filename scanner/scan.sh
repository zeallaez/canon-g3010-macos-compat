#!/bin/zsh
set -eu

readonly DEFAULT_QUEUE="Canon_G3010"
readonly DEFAULT_SERVICE_NAME="Canon G3010 series"
readonly DEFAULT_SERVICE_TYPE="_printer._tcp"
readonly DEFAULT_IMAGE="canon-g3010-macos-compat-scanner:1.1.0"
readonly DEVICE_NAME="airscan:w0:Canon G3010 WSD"

script_dir="${0:A:h}"
runtime_dir="${script_dir}"
if [[ ! -f "${runtime_dir}/Dockerfile" ]]; then
  runtime_dir="/usr/local/libexec/canon-g3010-macos-compat/scanner"
fi

printer_ip=""
queue_name="${DEFAULT_QUEUE}"
output_path="${PWD}/canon-g3010-scan-$(/bin/date '+%Y%m%d-%H%M%S').jpg"
resolution="300"
scan_mode="color"
paper="a4"
format="jpeg"
action="scan"
image_name="${CANON_G3010_SCAN_IMAGE:-${DEFAULT_IMAGE}}"
temporary_dir=""

usage() {
  cat <<'EOF'
Canon G3010 network scanner (WSD/SANE)

Usage:
  ./scanner/scan.sh [options]

Options:
  --ip ADDRESS       Printer IPv4 address. If omitted, use the installed
                     CUPS queue or DNS-SD service discovery.
  --queue NAME       CUPS queue used for address discovery
                     (default: Canon_G3010).
  --output FILE      Destination file (default: timestamped JPEG in the
                     current directory).
  --resolution DPI   150, 300, or 600 (default: 300).
  --mode MODE        color or gray (default: color).
  --paper SIZE       a4, letter, or full (default: a4).
  --format FORMAT    jpeg, png, or tiff (default: jpeg).
  --list             Detect the scanner without scanning.
  --build             Build or rebuild the local scanner runtime.
  -h, --help         Show this help.

Examples:
  ./scanner/scan.sh --ip 192.168.1.50 --output scan.jpg
  ./scanner/scan.sh --resolution 600 --mode gray --format png \
    --output document.png
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
  lookup_file="$(/usr/bin/mktemp -t canon-g3010-dnssd)"

  /usr/bin/dns-sd \
    -L "${DEFAULT_SERVICE_NAME}" \
    "${DEFAULT_SERVICE_TYPE}" \
    local. >"${lookup_file}" 2>&1 &
  lookup_pid=$!

  for i in {1..10}; do
    if /usr/bin/grep -q "can be reached at" "${lookup_file}"; then
      break
    fi
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

ensure_docker() {
  command -v docker >/dev/null 2>&1 ||
    fail "Docker Desktop is required. Install and start it, then retry."
  docker info >/dev/null 2>&1 ||
    fail "Docker Desktop is installed but not running."
}

build_image() {
  [[ -f "${runtime_dir}/Dockerfile" ]] ||
    fail "scanner runtime is missing: ${runtime_dir}/Dockerfile"

  info "Building the open-source SANE scanner runtime"
  docker build \
    --tag "${image_name}" \
    "${runtime_dir}"
}

ensure_image() {
  if ! docker image inspect "${image_name}" >/dev/null 2>&1; then
    build_image
  fi
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
  fail "the host wrapper currently supports macOS only"

validate_safe_token "queue name" "${queue_name}"
[[ "${resolution}" == "150" || "${resolution}" == "300" || "${resolution}" == "600" ]] ||
  fail "--resolution must be 150, 300, or 600"
[[ "${scan_mode}" == "color" || "${scan_mode}" == "gray" ]] ||
  fail "--mode must be color or gray"
[[ "${paper}" == "a4" || "${paper}" == "letter" || "${paper}" == "full" ]] ||
  fail "--paper must be a4, letter, or full"
[[ "${format}" == "jpeg" || "${format}" == "png" || "${format}" == "tiff" ]] ||
  fail "--format must be jpeg, png, or tiff"

ensure_docker

if [[ "${action}" == "build" ]]; then
  build_image
  info "Scanner runtime ready: ${image_name}"
  exit 0
fi

ensure_image

if [[ -z "${printer_ip}" ]]; then
  discovered_host="$(discover_queue_host)"
  if [[ -z "${discovered_host}" ]]; then
    info "The CUPS queue was not found; trying DNS-SD discovery"
    discovered_host="$(discover_dnssd_host)"
  fi
  [[ -n "${discovered_host}" ]] ||
    fail "printer address discovery failed; rerun with --ip ADDRESS"
  printer_ip="$(resolve_ipv4 "${discovered_host}")"
fi

validate_ipv4 "${printer_ip}" ||
  fail "could not resolve a valid IPv4 address; rerun with --ip ADDRESS"

temporary_dir="$(/usr/bin/mktemp -d -t canon-g3010-scan)"
config_path="${temporary_dir}/airscan.conf"
{
  print -- "[devices]"
  print -- "\"Canon G3010 WSD\" = http://${printer_ip}:80/wsd/scanservice.cgi, WSD"
  print -- ""
  print -- "[options]"
  print -- "discovery = disable"
  print -- "protocol = manual"
  print -- "model = hardware"
} >"${config_path}"

typeset -a docker_mounts
docker_mounts=(
  --rm
  --mount "type=bind,source=${config_path},target=/etc/sane.d/airscan.conf,readonly"
)

if [[ "${action}" == "list" ]]; then
  info "Checking WSD scanner at ${printer_ip}"
  docker run "${docker_mounts[@]}" "${image_name}" -L
  exit 0
fi

case "${scan_mode}" in
  color) sane_mode="Color" ;;
  gray) sane_mode="Gray" ;;
esac

case "${paper}" in
  a4)
    scan_width="210"
    scan_height="296.672"
    ;;
  letter)
    scan_width="215.9"
    scan_height="279.4"
    ;;
  full)
    scan_width="215.9"
    scan_height="296.672"
    ;;
esac

if [[ "${output_path}" != /* ]]; then
  output_path="${PWD}/${output_path}"
fi
output_dir="${output_path:h}"
output_file="${output_path:t}"
[[ -d "${output_dir}" ]] ||
  fail "output directory does not exist: ${output_dir}"
[[ -n "${output_file}" && "${output_file}" != "." && "${output_file}" != ".." ]] ||
  fail "invalid output file"

info "Scanning ${paper:u}, ${resolution} dpi, ${sane_mode} from ${printer_ip}"
docker run \
  "${docker_mounts[@]}" \
  --mount "type=bind,source=${output_dir},target=/output" \
  "${image_name}" \
  --device-name "${DEVICE_NAME}" \
  --format="${format}" \
  --resolution "${resolution}" \
  --mode "${sane_mode}" \
  --source Flatbed \
  -x "${scan_width}" \
  -y "${scan_height}" \
  --output-file "/output/${output_file}"

[[ -s "${output_path}" ]] || fail "scanner returned no output"
info "Saved: ${output_path}"
