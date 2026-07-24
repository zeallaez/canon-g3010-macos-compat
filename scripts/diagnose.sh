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

section "WSD/SANE scanner runtime"
support_runtime="${HOME}/Library/Application Support/Canon G3010 macOS Compat/scanner-native"
system_runtime="/usr/local/libexec/canon-g3010-macos-compat/scanner-native"
source_runtime="./build/native-runtime"
if [[ -x "${support_runtime}/bin/scanimage" ]]; then
  native_runtime="${support_runtime}"
elif [[ -x "${system_runtime}/bin/scanimage" ]]; then
  native_runtime="${system_runtime}"
elif [[ -x "${source_runtime}/bin/scanimage" ]]; then
  native_runtime="${source_runtime}"
else
  native_runtime=""
fi
if [[ -n "${native_runtime}" ]]; then
  print -- "Native runtime: ${native_runtime}"
  if [[ -x "${native_runtime}/bin/canon-g3010-escl-bridge" ]]; then
    print -- "Image Capture engine: direct WSD-to-eSCL"
  elif [[ -x "${native_runtime}/bin/airsaned" ]]; then
    print -- "Image Capture engine: legacy AirSane migration fallback"
  else
    print -- "Image Capture engine: missing"
  fi
else
  print -- "Native runtime: not built or installed"
fi
print -- "Docker Desktop: not required"
print -- "Scanner test: ./scanner/scan.sh --ip ADDRESS --list"

section "macOS Image Capture bridge"
if [[ -x "./scanner/bridge/bridge.sh" ]]; then
  ./scanner/bridge/bridge.sh status
elif [[ -x "/usr/local/bin/canon-g3010-scanner-bridge" ]]; then
  /usr/local/bin/canon-g3010-scanner-bridge status
else
  print -- "Image Capture bridge: not installed"
fi

section "Notes"
print -- "This report is read-only."
print -- "Redact hostnames or serial-like identifiers before posting publicly."
