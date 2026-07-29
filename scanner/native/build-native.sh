#!/bin/zsh
set -eu

readonly SANE_AIRSCAN_COMMIT="9da18d88c88f542671b24fc0433dd7d69dcb0132"
readonly AVAHI_VERSION="0.9-rc5"

script_dir="${0:A:h}"
repo_root="${script_dir:h:h}"
build_root="${1:-${repo_root}/build/native}"
downloads="${build_root}/downloads"
sources="${build_root}/sources"
objects="${build_root}/objects"
runtime="${repo_root}/build/native-runtime"
signing_config="${CANON_G3010_SIGNING_CONFIG:-${HOME}/Library/Application Support/Canon G3010 macOS Compat/signing-identity}"

fail() {
  print -u2 -- "Error: $*"
  exit 1
}

info() {
  print -- "==> $*"
}

resolve_signing_identity() {
  local configured="${CANON_G3010_CODESIGN_IDENTITY:-}"
  local record
  typeset -a candidates

  if [[ -z "${configured}" && -s "${signing_config}" ]]; then
    configured="$(/usr/bin/head -n 1 "${signing_config}")"
  fi

  if [[ -n "${configured}" ]]; then
    record="$(
      /usr/bin/security find-identity -v -p codesigning |
        /usr/bin/awk -v wanted="${configured}" \
          '$2 == wanted && /"Apple Development:/ { print; exit }'
    )"
    [[ -n "${record}" ]] ||
      fail "pinned Apple Development identity ${configured} is unavailable"
    print -r -- "${configured}"
    return
  fi

  candidates=("${(@f)$(
    /usr/bin/security find-identity -v -p codesigning |
      /usr/bin/awk '/"Apple Development:/ { print $2 }'
  )}")
  if (( ${#candidates[@]} == 1 )); then
    print -r -- "${candidates[1]}"
    return
  fi

  if [[ "${CI:-}" == "true" || "${CANON_G3010_ALLOW_ADHOC:-no}" == "yes" ]]; then
    print -- "-"
    return
  fi

  fail "no unique Apple Development identity; run scripts/configure-signing.sh or explicitly set CANON_G3010_ALLOW_ADHOC=yes"
}

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] ||
  fail "the native scanner runtime can only be built on macOS"

command -v brew >/dev/null 2>&1 ||
  fail "Homebrew is required for maintainer build dependencies"
for formula in sane-backends gnutls jpeg-turbo libpng libtiff; do
  brew --prefix "${formula}" >/dev/null 2>&1 ||
    fail "missing build dependency: brew install ${formula}"
done

readonly brew_prefix="$(brew --prefix)"
readonly sane_prefix="$(brew --prefix sane-backends)"
readonly gnutls_prefix="$(brew --prefix gnutls)"
readonly jpeg_prefix="$(brew --prefix jpeg-turbo)"
readonly png_prefix="$(brew --prefix libpng)"
readonly tiff_prefix="$(brew --prefix libtiff)"
readonly sdk_root="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
readonly signing_identity="$(resolve_signing_identity)"

signing_authority=""
signing_team_id=""
if [[ "${signing_identity}" == "-" ]]; then
  info "Using explicit ad-hoc signing (CI or CANON_G3010_ALLOW_ADHOC=yes)"
else
  identity_record="$(
    /usr/bin/security find-identity -v -p codesigning |
      /usr/bin/awk -v wanted="${signing_identity}" '$2 == wanted { print; exit }'
  )"
  signing_authority="$(
    print -r -- "${identity_record}" |
      /usr/bin/sed -E \
        's/^[[:space:]]*[0-9]+\)[[:space:]]+[A-F0-9]+[[:space:]]+"([^"]+)".*$/\1/'
  )"
  signing_team_id="$(
    /usr/bin/security find-certificate -c "${signing_authority}" -p |
      /usr/bin/openssl x509 -noout -subject |
      /usr/bin/sed -nE 's#.*\/OU=([^/]+).*#\1#p'
  )"
  [[ -n "${signing_team_id}" ]] ||
    fail "could not determine the Apple Development Team ID"
  info "Signing native runtime with Apple Development team ${signing_team_id}"
fi

/bin/mkdir -p "${downloads}" "${sources}" "${objects}"
/bin/rm -rf "${runtime}"
/bin/mkdir -p \
  "${runtime}/bin" \
  "${runtime}/lib/sane" \
  "${runtime}/licenses/sane-airscan"

fetch() {
  local url="$1"
  local destination="$2"
  if [[ ! -s "${destination}" ]]; then
    info "Downloading ${url}"
    /usr/bin/curl --fail --location --retry 3 --silent --show-error \
      "${url}" --output "${destination}"
  fi
}

extract_clean() {
  local archive="$1"
  local destination="$2"
  /bin/rm -rf "${destination}"
  /bin/mkdir -p "${destination}"
  /usr/bin/tar -xzf "${archive}" -C "${destination}" --strip-components=1
}

sane_archive="${downloads}/sane-airscan-${SANE_AIRSCAN_COMMIT}.tar.gz"
avahi_archive="${downloads}/avahi-${AVAHI_VERSION}.tar.gz"

fetch \
  "https://github.com/alexpevzner/sane-airscan/archive/${SANE_AIRSCAN_COMMIT}.tar.gz" \
  "${sane_archive}"
fetch \
  "https://github.com/avahi/avahi/archive/refs/tags/v${AVAHI_VERSION}.tar.gz" \
  "${avahi_archive}"

sane_source="${sources}/sane-airscan"
avahi_source="${sources}/avahi"

extract_clean "${sane_archive}" "${sane_source}"
extract_clean "${avahi_archive}" "${avahi_source}"

info "Applying the audited macOS portability patches"
(
  cd "${sane_source}"
  /usr/bin/patch -p1 <"${script_dir}/patches/sane-airscan-macos.patch"
)
/bin/cp -X \
  "${script_dir}/airscan-macos-compat.h" \
  "${script_dir}/airscan-macos-compat.c" \
  "${script_dir}/airscan-mdns-disabled.c" \
  "${sane_source}/"

typeset -a sane_sources
sane_sources=("${sane_source}/airscan.c")
for file in "${sane_source}"/airscan-*.c; do
  [[ "${file:t}" == "airscan-mdns.c" ]] && continue
  sane_sources+=("${file}")
done
sane_sources+=(
  "${sane_source}/sane_strstatus.c"
  "${sane_source}/http_parser.c"
  "${avahi_source}/avahi-common/simple-watch.c"
  "${avahi_source}/avahi-common/timeval.c"
  "${avahi_source}/avahi-common/malloc.c"
)

info "Building the native WSD SANE backend"
/usr/bin/xcrun clang \
  -std=gnu11 \
  -O2 \
  -fPIC \
  -pthread \
  -D__APPLE_USE_RFC_3542=1 \
  -DOS_HAVE_AF_ROUTE=1 \
  -DOS_HAVE_SYS_ENDIAN_H=1 \
  -DCONFIG_SANE_CONFIG_DIR='"/Library/Application Support/Canon G3010 macOS Compat/sane.d"' \
  -include "${sane_source}/airscan-macos-compat.h" \
  -I"${sane_source}" \
  -I"${avahi_source}" \
  -I"${sane_prefix}/include" \
  -I"${sdk_root}/usr/include/libxml2" \
  -I"${gnutls_prefix}/include" \
  -I"${jpeg_prefix}/include" \
  -I"${png_prefix}/include" \
  -I"${tiff_prefix}/include" \
  "${sane_sources[@]}" \
  -dynamiclib \
  -Wl,-install_name,@rpath/libsane-airscan.1.so \
  -L"${gnutls_prefix}/lib" \
  -L"${jpeg_prefix}/lib" \
  -L"${png_prefix}/lib" \
  -L"${tiff_prefix}/lib" \
  -lxml2 \
  -lgnutls \
  -ljpeg \
  -lpng \
  -ltiff \
  -o "${runtime}/lib/sane/libsane-airscan.1.so"

(
  cd "${runtime}/lib/sane"
  /bin/ln -sf libsane-airscan.1.so libsane-airscan.so
)

info "Building the lightweight direct eSCL bridge"
/usr/bin/xcrun clang++ \
  -std=c++17 \
  -O2 \
  -pthread \
  -Wall \
  -Wextra \
  -Werror \
  -mmacosx-version-min=11.0 \
  "${script_dir}/direct-escl-bridge.cpp" \
  -o "${runtime}/bin/canon-g3010-escl-bridge"

/bin/cp -X "${sane_prefix}/bin/scanimage" "${runtime}/bin/scanimage"

for license in COPYING LICENSE; do
  if [[ -f "${sane_source}/${license}" ]]; then
    /bin/cp -X "${sane_source}/${license}" \
      "${runtime}/licenses/sane-airscan/${license}"
  fi
done

typeset -a queue
typeset -A queued
queue=(
  "${runtime}/bin/canon-g3010-escl-bridge"
  "${runtime}/bin/scanimage"
  "${runtime}/lib/sane/libsane-airscan.1.so"
)
for current in "${queue[@]}"; do
  queued[$current]=1
done

info "Bundling native dynamic-library dependencies"
while (( ${#queue[@]} > 0 )); do
  current="${queue[1]}"
  queue[1]=()

  while IFS= read -r dependency; do
    dependency_name="${dependency:t}"
    if [[ "${dependency}" == "${brew_prefix}/"* ]]; then
      dependency_source="${dependency}"
    elif [[ "${dependency}" == @rpath/* &&
            -e "${brew_prefix}/lib/${dependency_name}" ]]; then
      dependency_source="${brew_prefix}/lib/${dependency_name}"
    else
      continue
    fi
    destination="${runtime}/lib/${dependency_name}"
    if [[ ! -e "${destination}" ]]; then
      /bin/cp -L -X "${dependency_source}" "${destination}"
    fi
    if [[ -z "${queued[$destination]:-}" ]]; then
      queued[$destination]=1
      queue+=("${destination}")
    fi
  done < <(
    /usr/bin/otool -L "${current}" |
      /usr/bin/tail -n +2 |
      /usr/bin/awk '{print $1}'
  )
done

rewrite_binary() {
  local binary="$1"
  local dependency dependency_name replacement signature_details

  while IFS= read -r dependency; do
    dependency_name="${dependency:t}"
    if [[ "${dependency}" == "${brew_prefix}/"* ]]; then
      :
    elif [[ "${dependency}" == @rpath/* &&
            -e "${runtime}/lib/${dependency_name}" ]]; then
      :
    else
      continue
    fi
    case "${binary}" in
      "${runtime}/bin/"*)
        replacement="@loader_path/../lib/${dependency_name}"
        ;;
      "${runtime}/lib/sane/"*)
        replacement="@loader_path/../${dependency_name}"
        ;;
      *)
        replacement="@loader_path/${dependency_name}"
        ;;
    esac
    /usr/bin/install_name_tool -change \
      "${dependency}" "${replacement}" "${binary}"
  done < <(
    /usr/bin/otool -L "${binary}" |
      /usr/bin/tail -n +2 |
      /usr/bin/awk '{print $1}'
  )

  case "${binary}" in
    "${runtime}/lib/"*.dylib|"${runtime}/lib/sane/"*.so)
      /usr/bin/install_name_tool -id "@loader_path/${binary:t}" "${binary}"
      ;;
  esac

  /usr/bin/codesign \
    --force \
    --sign "${signing_identity}" \
    --timestamp=none \
    "${binary}" >/dev/null
  /usr/bin/codesign --verify --strict --verbose=2 "${binary}" >/dev/null

  if [[ "${signing_identity}" != "-" ]]; then
    signature_details="$(/usr/bin/codesign -dv --verbose=4 "${binary}" 2>&1)"
    print -r -- "${signature_details}" |
      /usr/bin/grep -F "Authority=${signing_authority}" >/dev/null ||
      fail "unexpected signing authority on ${binary}"
    print -r -- "${signature_details}" |
      /usr/bin/grep -F "TeamIdentifier=${signing_team_id}" >/dev/null ||
      fail "unexpected signing team on ${binary}"
  fi
}

while IFS= read -r binary; do
  if /usr/bin/file "${binary}" | /usr/bin/grep -q "Mach-O"; then
    rewrite_binary "${binary}"
  fi
done < <(/usr/bin/find "${runtime}" -type f)

if /usr/bin/find "${runtime}" -type f -print0 |
  /usr/bin/xargs -0 /usr/bin/otool -L 2>/dev/null |
  /usr/bin/grep -F "${brew_prefix}/" >/dev/null; then
  fail "the staged runtime still contains Homebrew install-name references"
fi

/bin/chmod 0755 \
  "${runtime}/bin/canon-g3010-escl-bridge" \
  "${runtime}/bin/scanimage"

if [[ "${signing_identity}" == "-" ]]; then
  print -- "mode=ad-hoc" >"${runtime}/CODE_SIGNING"
else
  {
    print -- "mode=apple-development"
    print -- "team_id=${signing_team_id}"
    print -- "certificate_sha1=${signing_identity}"
  } >"${runtime}/CODE_SIGNING"
fi

info "Native runtime built at ${runtime}"
/usr/bin/du -sh "${runtime}"
