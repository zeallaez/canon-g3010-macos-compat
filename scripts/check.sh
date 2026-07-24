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
  "${repo_root}/scanner/native/build-native.sh"
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

for bridge_file in \
  scanner/bridge/bridge.sh \
  scanner/native/airscan-macos-compat.c \
  scanner/native/airscan-macos-compat.h \
  scanner/native/airscan-mdns-disabled.c \
  scanner/native/direct-escl-bridge.cpp \
  scanner/native/build-native.sh \
  scanner/native/patches/sane-airscan-macos.patch; do
  [[ -s "${repo_root}/${bridge_file}" ]] || {
    print -u2 -- "Missing or empty: ${bridge_file}"
    exit 1
  }
done

if [[ "$(/usr/bin/uname -s)" == "Darwin" ]]; then
  /usr/bin/xcrun clang++ \
    -std=c++17 \
    -pthread \
    -Wall \
    -Wextra \
    -Werror \
    -fsyntax-only \
    "${repo_root}/scanner/native/direct-escl-bridge.cpp"
fi

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
