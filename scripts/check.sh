#!/bin/zsh
set -eu

script_dir="${0:A:h}"
repo_root="${script_dir:h}"

typeset -a scripts
scripts=(
  "${repo_root}/src/install.sh"
  "${repo_root}/src/uninstall.sh"
  "${repo_root}/scripts/diagnose.sh"
  "${repo_root}/scripts/build-pkg.sh"
  "${repo_root}/scripts/check.sh"
  "${repo_root}/scanner/scan.sh"
  "${repo_root}/scanner/bridge/bridge.sh"
  "${repo_root}/scanner/bridge/entrypoint.sh"
  "${repo_root}/package/scripts/preinstall"
  "${repo_root}/package/scripts/postinstall"
)

for script in "${scripts[@]}"; do
  /bin/zsh -n "${script}"
  [[ -x "${script}" ]] || {
    print -u2 -- "Not executable: ${script}"
    exit 1
  }
done

"${repo_root}/src/install.sh" --help >/dev/null
"${repo_root}/src/uninstall.sh" --help >/dev/null
"${repo_root}/scanner/scan.sh" --help >/dev/null
"${repo_root}/scanner/bridge/bridge.sh" --help >/dev/null

[[ -s "${repo_root}/scanner/Dockerfile" ]] || {
  print -u2 -- "Missing or empty: scanner/Dockerfile"
  exit 1
}

for bridge_file in \
  scanner/bridge/Dockerfile \
  scanner/bridge/bridge.sh \
  scanner/bridge/entrypoint.sh; do
  [[ -s "${repo_root}/${bridge_file}" ]] || {
    print -u2 -- "Missing or empty: ${bridge_file}"
    exit 1
  }
done

for doc in \
  README.md \
  README.zh-CN.md \
  docs/HOW_IT_WORKS.md \
  docs/HOW_IT_WORKS.zh-CN.md \
  LICENSE \
  NOTICE.md; do
  [[ -s "${repo_root}/${doc}" ]] || {
    print -u2 -- "Missing or empty: ${doc}"
    exit 1
  }
done

print -- "All checks passed."
