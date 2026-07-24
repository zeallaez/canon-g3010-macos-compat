#!/bin/zsh
set -eu

queue_name="Canon_G3010"
assume_yes="no"

usage() {
  cat <<'EOF'
Canon G3010 macOS compatibility uninstaller

Usage:
  ./src/uninstall.sh [--queue NAME] [--yes]

This removes only the compatibility CUPS queue. It does not remove Canon's
official G3000 driver. If the per-user scanner bridge is installed, it is
stopped and removed as well.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --queue)
      (( $# >= 2 )) || {
        print -u2 -- "Error: --queue requires a value"
        exit 2
      }
      queue_name="$2"
      shift 2
      ;;
    --yes)
      assume_yes="yes"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      print -u2 -- "Error: unknown option: $1"
      exit 2
      ;;
  esac
done

if [[ ! "${queue_name}" =~ '^[A-Za-z0-9._-]+$' ]]; then
  print -u2 -- "Error: invalid queue name: ${queue_name}"
  exit 2
fi

if [[ "${assume_yes}" != "yes" ]]; then
  print -n -- "Remove the ${queue_name} queue and scanner bridge? [y/N] "
  read -r answer
  [[ "${answer:l}" == "y" || "${answer:l}" == "yes" ]] || {
    print -- "Cancelled."
    exit 0
  }
fi

if /usr/bin/lpstat -p "${queue_name}" >/dev/null 2>&1; then
  /usr/sbin/lpadmin -x "${queue_name}"
  print -- "Removed ${queue_name}."
else
  print -- "Queue ${queue_name} is not installed."
fi

bridge="/usr/local/bin/canon-g3010-scanner-bridge"
if [[ ! -x "${bridge}" ]]; then
  source_bridge="${0:A:h:h}/scanner/bridge/bridge.sh"
  [[ -x "${source_bridge}" ]] && bridge="${source_bridge}"
fi
if [[ -x "${bridge}" ]]; then
  "${bridge}" uninstall
fi

print -- "Canon's official G3000 driver was left installed."
