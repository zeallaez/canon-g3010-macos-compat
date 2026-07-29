#!/bin/zsh
set -eu

script_dir="${0:A:h}"

export CANON_G3010_BRIDGE_LIBRARY_ONLY="yes"
export CANON_G3010_SERVICE_PORT="18090"
export CANON_G3010_PRESENCE_PRIMARY_PORT="18080"
export CANON_G3010_PRESENCE_SECONDARY_PORT="18515"
export CANON_G3010_PRESENCE_TIMEOUT="1"
source "${script_dir}/bridge.sh"

listener_pid=""

cleanup_test() {
  [[ -z "${listener_pid}" ]] ||
    /bin/kill "${listener_pid}" 2>/dev/null || true
}
trap cleanup_test EXIT INT TERM

fail_test() {
  print -u2 -- "Monitor test failed: $*"
  exit 1
}

serve_once() {
  local port="$1"
  local body="${2:-}"
  local response

  if [[ -n "${body}" ]]; then
    response="$(
      /usr/bin/printf \
        'HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
        "${#body}" "${body}"
    )"
    /usr/bin/printf '%s' "${response}" |
      /usr/bin/nc -l 127.0.0.1 "${port}" >/dev/null &
  else
    /usr/bin/nc -l 127.0.0.1 "${port}" >/dev/null &
  fi
  listener_pid=$!
}

probe_printer_presence "not-an-address" &&
  fail_test "invalid addresses must fail"

probe_printer_presence "127.0.0.1" &&
  fail_test "closed presence ports must fail"

serve_once "${PRESENCE_PRIMARY_PORT}"
/bin/sleep 0.2
probe_printer_presence "127.0.0.1" ||
  fail_test "an open primary port must report the printer present"
wait "${listener_pid}" 2>/dev/null || true
listener_pid=""

serve_once "${PRESENCE_SECONDARY_PORT}"
/bin/sleep 0.2
probe_printer_presence "127.0.0.1" ||
  fail_test "an open secondary port must report the printer present"
wait "${listener_pid}" 2>/dev/null || true
listener_pid=""

processing_xml='<pwg:JobState>Processing</pwg:JobState>'
serve_once "${SERVICE_PORT}" "${processing_xml}"
/bin/sleep 0.2
bridge_has_active_job ||
  fail_test "a processing eSCL job must suppress offline recovery"
wait "${listener_pid}" 2>/dev/null || true
listener_pid=""

idle_xml='<pwg:JobState>Completed</pwg:JobState>'
serve_once "${SERVICE_PORT}" "${idle_xml}"
/bin/sleep 0.2
bridge_has_active_job &&
  fail_test "a completed eSCL job must not suppress offline recovery"
wait "${listener_pid}" 2>/dev/null || true
listener_pid=""

print -- "Bridge monitor tests passed."
