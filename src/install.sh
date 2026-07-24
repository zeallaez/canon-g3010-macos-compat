#!/bin/zsh
set -eu

readonly DEFAULT_QUEUE="Canon_G3010"
readonly DEFAULT_SERVICE_NAME="Canon G3010 series"
readonly DEFAULT_SERVICE_TYPE="_printer._tcp"
readonly DEFAULT_SERVICE_URI="Canon%20G3010%20series._printer._tcp.local."
readonly DEFAULT_PPD_MODEL="Library/Printers/PPDs/Contents/Resources/CanonIJG3000series.ppd.gz"
readonly DEFAULT_PPD_PATH="/${DEFAULT_PPD_MODEL}"
readonly TEST_PAGE="/usr/share/cups/data/testprint"
readonly CANON_DOWNLOAD_URL="https://asia.canon/en/support/0101155813?model=PIXMA%20G3000"

queue_name="${DEFAULT_QUEUE}"
printer_host=""
printer_uuid=""
printer_uri=""
explicit_host="no"
set_default="yes"
print_test_page="no"
dry_run="no"

usage() {
  cat <<'EOF'
Canon G3010 macOS compatibility installer

Usage:
  ./src/install.sh [options]

Options:
  --host HOST       Use an explicit printer hostname, for example:
                    0E25AA000000.local.
  --queue NAME      Set the CUPS queue name (default: Canon_G3010).
  --test            Send one macOS A4 color test page after installation.
  --no-default      Do not make this queue the system default.
  --dry-run         Validate and show the selected configuration without
                    changing CUPS or printing.
  -h, --help        Show this help.

Without --host, the installer resolves the DNS-SD service named
"Canon G3010 series" on the local network.
EOF
}

fail() {
  print -u2 -- "Error: $*"
  exit 1
}

info() {
  print -- "==> $*"
}

validate_safe_token() {
  local label="$1"
  local value="$2"

  if [[ ! "${value}" =~ '^[A-Za-z0-9._-]+$' ]]; then
    fail "${label} contains unsupported characters: ${value}"
  fi
}

discover_identity() {
  local lookup_file lookup_pid i
  lookup_file="$(/usr/bin/mktemp -t canon-g3010-dnssd)"

  /usr/bin/dns-sd \
    -L "${DEFAULT_SERVICE_NAME}" \
    "${DEFAULT_SERVICE_TYPE}" \
    local. >"${lookup_file}" 2>&1 &
  lookup_pid=$!

  for i in {1..10}; do
    if /usr/bin/grep -q "can be reached at" "${lookup_file}" &&
       /usr/bin/grep -q "UUID=" "${lookup_file}"; then
      break
    fi
    /bin/sleep 1
  done

  /bin/kill "${lookup_pid}" 2>/dev/null || true
  wait "${lookup_pid}" 2>/dev/null || true

  printer_host="$(
    /usr/bin/sed -nE \
      's/.* can be reached at ([^: ]+):[0-9]+.*/\1/p' \
      "${lookup_file}" |
      /usr/bin/head -n 1
  )"
  printer_uuid="$(
    /usr/bin/sed -nE 's/.*(^|[[:space:]])UUID=([^[:space:]]+).*/\2/p' \
      "${lookup_file}" |
      /usr/bin/head -n 1
  )"

  /bin/rm -f "${lookup_file}"
}

while (( $# > 0 )); do
  case "$1" in
    --host)
      (( $# >= 2 )) || fail "--host requires a value"
      printer_host="$2"
      explicit_host="yes"
      shift 2
      ;;
    --queue)
      (( $# >= 2 )) || fail "--queue requires a value"
      queue_name="$2"
      shift 2
      ;;
    --test)
      print_test_page="yes"
      shift
      ;;
    --no-default)
      set_default="no"
      shift
      ;;
    --dry-run)
      dry_run="yes"
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
  fail "this installer supports macOS only"

validate_safe_token "queue name" "${queue_name}"

if [[ ! -f "${DEFAULT_PPD_PATH}" ]]; then
  print -u2 -- "Canon's G3000 CUPS dependency was not found:"
  print -u2 -- "  ${DEFAULT_PPD_PATH}"
  print -u2 -- ""
  print -u2 -- "Install it from Canon, then run this installer again:"
  print -u2 -- "  ${CANON_DOWNLOAD_URL}"
  exit 3
fi

if [[ -z "${printer_host}" ]]; then
  info "Discovering ${DEFAULT_SERVICE_NAME} with DNS-SD"
  discover_identity
fi

[[ -n "${printer_host}" ]] ||
  fail "printer discovery failed; rerun with --host HOST"

validate_safe_token "printer host" "${printer_host}"

if [[ "${explicit_host}" == "no" &&
      "${printer_uuid}" =~ '^[A-Fa-f0-9-]{32,36}$' ]]; then
  printer_uri="dnssd://${DEFAULT_SERVICE_URI}/?uuid=${printer_uuid}"
else
  printer_uri="lpd://${printer_host}/auto"
fi

info "Queue: ${queue_name}"
info "Printer: ${printer_host}"
info "Multifunction UUID: ${printer_uuid:-unavailable}"
info "Transport: ${printer_uri}"
info "Renderer: Canon G3000 series CUPS/BJRaster3 compatibility"

if [[ "${dry_run}" == "yes" ]]; then
  info "Dry run complete; no system changes were made"
  exit 0
fi

info "Creating the compatibility print queue"
/usr/sbin/lpadmin \
  -p "${queue_name}" \
  -E \
  -v "${printer_uri}" \
  -m "${DEFAULT_PPD_MODEL}" \
  -D "Canon G3010 series (Mac compatibility)" \
  -L "Local Network" \
  -o printer-is-shared=false

/usr/bin/lpoptions \
  -p "${queue_name}" \
  -o PageSize=A4 \
  -o CNIJMediaType=0 \
  -o CNIJPrintQuality=10 \
  -o CNIJGrayScale=0 >/dev/null

if [[ "${set_default}" == "yes" ]]; then
  /usr/sbin/lpadmin -d "${queue_name}"
fi

info "Compatibility queue installed"
/usr/bin/lpstat -p "${queue_name}" -l
/usr/bin/lpstat -v "${queue_name}"

if [[ "${print_test_page}" == "yes" ]]; then
  [[ -f "${TEST_PAGE}" ]] ||
    fail "macOS test page is unavailable: ${TEST_PAGE}"

  info "Sending one A4 color test page"
  /usr/bin/lp \
    -d "${queue_name}" \
    -o PageSize=A4 \
    -o CNIJMediaType=0 \
    -o CNIJPrintQuality=10 \
    -o CNIJGrayScale=0 \
    "${TEST_PAGE}"
fi
