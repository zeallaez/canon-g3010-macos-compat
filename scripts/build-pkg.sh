#!/bin/zsh
set -eu

# Prevent macOS copyfile metadata from becoming ._ AppleDouble payload files.
export COPYFILE_DISABLE=1
export COPY_EXTENDED_ATTRIBUTES_DISABLE=1

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
version="$(<"${repo_root}/VERSION")"
package_name="Canon-G3010-macOS-Compat-${version}"
package_path="${repo_root}/dist/${package_name}.pkg"
archive_path="${repo_root}/dist/${package_name}-source.zip"
checksum_path="${repo_root}/dist/SHA256SUMS"
payload_root="$(/usr/bin/mktemp -d "/private/tmp/canon-g3010-pkgroot.XXXXXX")"
native_runtime="${repo_root}/build/native-runtime"

cleanup() {
  case "${payload_root}" in
    /private/tmp/canon-g3010-pkgroot.*)
      /bin/rm -rf "${payload_root}"
      ;;
  esac
}
trap cleanup EXIT INT TERM

/bin/rm -f "${package_path}" "${archive_path}" "${checksum_path}"

"${repo_root}/scanner/native/build-native.sh"

/bin/mkdir -p \
  "${payload_root}/usr/local/bin" \
  "${payload_root}/usr/local/libexec/canon-g3010-macos-compat/scanner-native"

/bin/cp -X \
  "${repo_root}/src/install.sh" \
  "${payload_root}/usr/local/libexec/canon-g3010-macos-compat/install.sh"

/bin/cp -X \
  "${repo_root}/src/uninstall.sh" \
  "${payload_root}/usr/local/libexec/canon-g3010-macos-compat/uninstall.sh"

/bin/cp -X \
  "${repo_root}/scanner/scan.sh" \
  "${payload_root}/usr/local/bin/canon-g3010-scan"

/bin/cp -X \
  "${repo_root}/scanner/bridge/bridge.sh" \
  "${payload_root}/usr/local/bin/canon-g3010-scanner-bridge"

/bin/cp -R -X \
  "${native_runtime}/." \
  "${payload_root}/usr/local/libexec/canon-g3010-macos-compat/scanner-native/"

/bin/chmod 0755 \
  "${payload_root}/usr/local/libexec/canon-g3010-macos-compat/install.sh" \
  "${payload_root}/usr/local/libexec/canon-g3010-macos-compat/uninstall.sh" \
  "${payload_root}/usr/local/bin/canon-g3010-scan" \
  "${payload_root}/usr/local/bin/canon-g3010-scanner-bridge" \
  "${payload_root}/usr/local/libexec/canon-g3010-macos-compat/scanner-native/bin/canon-g3010-escl-bridge" \
  "${payload_root}/usr/local/libexec/canon-g3010-macos-compat/scanner-native/bin/scanimage" \
  "${repo_root}/package/scripts/preinstall" \
  "${repo_root}/package/scripts/postinstall"

# Homebrew bottles can be installed read-only. The package staging copy must
# be writable so macOS can remove provenance metadata before pkgbuild.
/bin/chmod -R u+w "${payload_root}"
/usr/bin/xattr -cr "${payload_root}"

/usr/bin/pkgbuild \
  --root "${payload_root}" \
  --scripts "${repo_root}/package/scripts" \
  --install-location / \
  --identifier "io.github.zeallaez.canon-g3010-macos-compat" \
  --version "${version}" \
  --ownership recommended \
  "${package_path}"

if ! /usr/bin/git -C "${repo_root}" rev-parse --verify HEAD >/dev/null 2>&1; then
  print -u2 -- "A Git commit is required before building the source archive."
  exit 1
fi

/usr/bin/git -C "${repo_root}" archive \
  --format=zip \
  --prefix="${package_name}/" \
  --output="${archive_path}" \
  HEAD

(
  cd "${repo_root}/dist"
  /usr/bin/shasum -a 256 \
    "${package_name}.pkg" \
    "${package_name}-source.zip" >"${checksum_path}"
)

print -- "Built:"
print -- "  ${package_path}"
print -- "  ${archive_path}"
print -- "  ${checksum_path}"
