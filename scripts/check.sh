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
