#!/bin/zsh
set -u

readonly QUEUE_NAME="${1:-Canon_G3010}"
readonly PPD_PATH="/Library/Printers/PPDs/Contents/Resources/CanonIJG3000series.ppd.gz"

section() {
  print -- ""
  print -- "## $*"
}

print -- "Canon G3010 macOS compatibility diagnostics"
print -- "Generated: $(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"

section "System"
/usr/bin/sw_vers
print -- "Architecture: $(/usr/bin/uname -m)"

section "Canon dependency"
if [[ -f "${PPD_PATH}" ]]; then
  print -- "Installed: ${PPD_PATH}"
  /usr/bin/gzip -dc "${PPD_PATH}" 2>/dev/null |
    /usr/bin/grep -E '^\*FileVersion:|^\*ModelName:|^\*cupsFilter:' |
    /usr/bin/head -n 10
else
  print -- "Missing: ${PPD_PATH}"
fi

section "CUPS queue"
if /usr/bin/lpstat -p "${QUEUE_NAME}" >/dev/null 2>&1; then
  /usr/bin/lpstat -p "${QUEUE_NAME}" -l
  /usr/bin/lpstat -v "${QUEUE_NAME}"
  /usr/bin/lpoptions -p "${QUEUE_NAME}" |
    /usr/bin/tr ' ' '\n' |
    /usr/bin/grep -E \
      '^(device-uri|printer-make-and-model|PageSize|CNIJMediaType|CNIJPrintQuality|CNIJGrayScale)='
else
  print -- "Queue ${QUEUE_NAME} is not installed."
fi

section "Visible printer services"
/usr/sbin/lpinfo -v 2>&1 |
  /usr/bin/grep -Ei 'G3010|canonijnetwork|network (ipp|lpd|dnssd)' ||
  print -- "No matching service was reported by lpinfo."

section "Notes"
print -- "This report is read-only."
print -- "Redact hostnames or serial-like identifiers before posting publicly."
