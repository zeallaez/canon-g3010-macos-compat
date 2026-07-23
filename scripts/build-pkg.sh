#!/bin/zsh
set -eu

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
version="$(<"${repo_root}/VERSION")"
package_name="Canon-G3010-macOS-Compat-${version}"
package_path="${repo_root}/dist/${package_name}.pkg"
archive_path="${repo_root}/dist/${package_name}-source.zip"
checksum_path="${repo_root}/dist/SHA256SUMS"
payload_root="$(/usr/bin/mktemp -d "${repo_root}/build/pkgroot.XXXXXX")"

cleanup() {
  case "${payload_root}" in
    "${repo_root}"/build/pkgroot.*)
      /bin/rm -rf "${payload_root}"
      ;;
  esac
}
trap cleanup EXIT INT TERM

/bin/rm -f "${package_path}" "${archive_path}" "${checksum_path}"

/bin/mkdir -p \
  "${payload_root}/usr/local/libexec/canon-g3010-macos-compat"

/bin/cp -X \
  "${repo_root}/src/install.sh" \
  "${payload_root}/usr/local/libexec/canon-g3010-macos-compat/install.sh"

/bin/cp -X \
  "${repo_root}/src/uninstall.sh" \
  "${payload_root}/usr/local/libexec/canon-g3010-macos-compat/uninstall.sh"

/bin/chmod 0755 \
  "${payload_root}/usr/local/libexec/canon-g3010-macos-compat/install.sh" \
  "${payload_root}/usr/local/libexec/canon-g3010-macos-compat/uninstall.sh" \
  "${repo_root}/package/scripts/preinstall" \
  "${repo_root}/package/scripts/postinstall"

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
