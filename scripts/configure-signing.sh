#!/bin/zsh
set -eu

readonly CONFIG_PATH="${CANON_G3010_SIGNING_CONFIG:-${HOME}/Library/Application Support/Canon G3010 macOS Compat/signing-identity}"

fail() {
  print -u2 -- "Error: $*"
  exit 1
}

usage() {
  cat <<'EOF'
Configure the Apple Development identity used to sign the native scanner bridge.

Usage:
  ./scripts/configure-signing.sh [--identity CERTIFICATE_SHA1]
  ./scripts/configure-signing.sh --status

The configuration stores only the public certificate fingerprint. The private
key remains in the macOS Keychain and is never exported.
EOF
}

identity_record() {
  local wanted="$1"
  /usr/bin/security find-identity -v -p codesigning |
    /usr/bin/awk -v wanted="${wanted}" \
      '$2 == wanted && /"Apple Development:/ { print; exit }'
}

describe_identity() {
  local identity="$1"
  local record
  record="$(identity_record "${identity}")"
  [[ -n "${record}" ]] || return 1
  print -r -- "${record}" |
    /usr/bin/sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+[A-F0-9]+[[:space:]]+"([^"]+)".*$/\1/'
}

action="configure"
requested_identity=""
while (( $# > 0 )); do
  case "$1" in
    --identity)
      (( $# >= 2 )) || fail "--identity requires a SHA-1 fingerprint"
      requested_identity="$2"
      shift 2
      ;;
    --status)
      action="status"
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

if [[ "${action}" == "status" ]]; then
  [[ -s "${CONFIG_PATH}" ]] || fail "no pinned signing identity is configured"
  configured_identity="$(/usr/bin/head -n 1 "${CONFIG_PATH}")"
  authority="$(describe_identity "${configured_identity}")" ||
    fail "the pinned Apple Development identity is unavailable in Keychain"
  print -- "Signing identity: ${authority}"
  print -- "Certificate SHA-1: ${configured_identity}"
  print -- "Configuration: ${CONFIG_PATH}"
  exit 0
fi

if [[ -z "${requested_identity}" ]]; then
  typeset -a candidates
  candidates=("${(@f)$(
    /usr/bin/security find-identity -v -p codesigning |
      /usr/bin/awk '/"Apple Development:/ { print $2 }'
  )}")
  if (( ${#candidates[@]} == 0 )); then
    fail "no Apple Development code-signing identity was found"
  elif (( ${#candidates[@]} > 1 )); then
    fail "multiple Apple Development identities found; pass --identity CERTIFICATE_SHA1"
  fi
  requested_identity="${candidates[1]}"
fi

authority="$(describe_identity "${requested_identity}")" ||
  fail "the requested fingerprint is not a valid Apple Development identity"

/bin/mkdir -p "${CONFIG_PATH:h}"
umask 077
print -r -- "${requested_identity}" >"${CONFIG_PATH}"
/bin/chmod 0600 "${CONFIG_PATH}"

print -- "Pinned signing identity: ${authority}"
print -- "Certificate SHA-1: ${requested_identity}"
print -- "Configuration: ${CONFIG_PATH}"
print -- "The private key remains in the macOS Keychain."
