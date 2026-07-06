#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly APP_NAME="Tsukimi"
readonly EXECUTABLE_NAME="tsukimi"
readonly MACOS_PACKAGES_FILE="${SCRIPT_DIR}/macos-packages.txt"
readonly RUST_TOOLCHAIN="${TSUKIMI_RUST_TOOLCHAIN:-nightly}"

BUILD_DIR="${REPO_ROOT}/build/macos"
OUTPUT_DIR="${REPO_ROOT}/dist/macos"
PROFILE="release"
DRY_RUN=0
CLEAN=0
SKIP_CODESIGN=0
INSTALL_DEPS="ask"
SIGN_IDENTITY="-"
SELF_SIGN_IDENTITY="Tsukimi Local Code Signing"
BUNDLE_PATCHED_MPV=1
BREW_BIN=""
BREW_PREFIX=""

COLOR_RESET=$'\033[0m'
COLOR_GREEN=$'\033[32m'
COLOR_RED=$'\033[31m'
COLOR_YELLOW=$'\033[33m'

usage() {
    cat <<'EOF'
Build a macOS .app bundle for Tsukimi.

Usage:
    scripts/build-macos-app.sh [options]

Options:
    --build-dir PATH      Meson build directory. Default: build/macos
    --output-dir PATH     Directory that receives Tsukimi.app. Default: dist/macos
    --profile PROFILE     Build profile: release or debug. Default: release
    --install-deps        Install missing Homebrew packages without prompting
    --no-install-deps     Do not install packages; print manual instructions
    --bundled-mpv         Build and bundle patched libmpv. Default on macOS
    --system-mpv          Link against Homebrew libmpv without bundling it
    --self-sign           Sign with the default self-signed identity
    --sign-identity NAME  Sign with a specific codesign identity
    --clean               Remove build output and restart all steps
    --dry-run             Print commands without executing them
    --skip-codesign       Do not codesign the generated app bundle
    -h, --help            Show this help text

Requirements:
    macOS with packages listed in scripts/macos-packages.txt.

Environment:
    TSUKIMI_BREW=/path/to/brew overrides Homebrew binary detection.
    TSUKIMI_BREW_PREFIX=/path overrides the prefix used by the app launcher.
    TSUKIMI_RUST_TOOLCHAIN=nightly overrides the Rust toolchain used by rustup.
EOF
}

log_status() {
    printf "%b%12s%b %s\n" "${COLOR_GREEN}" "$1" "${COLOR_RESET}" "$2"
}

log_warn() {
    printf "%b%12s%b %s\n" "${COLOR_YELLOW}" "warning" "${COLOR_RESET}" "$2"
}

log_error() {
    printf "%b%12s%b %s\n" "${COLOR_RED}" "error[E001]" "${COLOR_RESET}" "$1" >&2
}

run() {
    log_status "Running" "$*"
    if [[ "${DRY_RUN}" == "0" ]]; then
        "$@"
    fi
}

write_file() {
    local path="$1"
    shift

    log_status "Writing" "${path}"
    if [[ "${DRY_RUN}" == "0" ]]; then
        mkdir -p "$(dirname "${path}")"
        printf "%s\n" "$@" >"${path}"
    fi
}

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --build-dir)
                BUILD_DIR="$(absolute_path "$2")"
                shift 2
                ;;
            --output-dir)
                OUTPUT_DIR="$(absolute_path "$2")"
                shift 2
                ;;
            --profile)
                PROFILE="$2"
                shift 2
                ;;
            --install-deps)
                INSTALL_DEPS="yes"
                shift
                ;;
            --no-install-deps)
                INSTALL_DEPS="no"
                shift
                ;;
            --bundled-mpv)
                BUNDLE_PATCHED_MPV=1
                shift
                ;;
            --system-mpv)
                BUNDLE_PATCHED_MPV=0
                shift
                ;;
            --self-sign)
                SIGN_IDENTITY="${SELF_SIGN_IDENTITY}"
                shift
                ;;
            --sign-identity)
                SIGN_IDENTITY="$2"
                shift 2
                ;;
            --clean)
                CLEAN=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --skip-codesign)
                SKIP_CODESIGN=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                log_error "unknown option: $1"
                usage
                exit 2
                ;;
        esac
    done
}

absolute_path() {
    local path="$1"

    if [[ "${path}" == /* ]]; then
        printf "%s\n" "${path}"
    else
        printf "%s/%s\n" "${REPO_ROOT}" "${path}"
    fi
}

validate_options() {
    case "${PROFILE}" in
        release | debug)
            ;;
        *)
            log_error "--profile must be either release or debug"
            exit 2
            ;;
    esac
}

host_is_macos() {
    [[ "$(uname -s)" == "Darwin" ]]
}

host_arch() {
    uname -m
}

brew_binary_candidates() {
    if [[ -n "${TSUKIMI_BREW:-}" ]]; then
        printf "%s\n" "${TSUKIMI_BREW}"
    fi

    if [[ "$(host_arch)" == "arm64" ]]; then
        printf "%s\n" "/opt/homebrew/bin/brew"
        printf "%s\n" "/usr/local/bin/brew"
    else
        printf "%s\n" "/usr/local/bin/brew"
        printf "%s\n" "/opt/homebrew/bin/brew"
    fi

    if command -v brew >/dev/null 2>&1; then
        command -v brew
    fi
}

detect_brew() {
    local candidate

    while IFS= read -r candidate; do
        if [[ -x "${candidate}" ]]; then
            BREW_BIN="${candidate}"
            BREW_PREFIX="$("${BREW_BIN}" --prefix)"
            return 0
        fi
    done < <(brew_binary_candidates)

    return 1
}

brew_packages() {
    awk '
        /^[[:space:]]*($|#)/ {
            next
        }

        {
            print $1
        }
    ' "${MACOS_PACKAGES_FILE}"
}

rust_toolchain_available() {
    command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1
}

configure_rust_toolchain() {
    export RUSTUP_TOOLCHAIN="${RUST_TOOLCHAIN}"
    log_status "Detected" "Rust toolchain override: ${RUSTUP_TOOLCHAIN}"
}

brew_install_packages() {
    local package

    while IFS= read -r package; do
        if [[ "${package}" == "rust" ]] && rust_toolchain_available; then
            continue
        fi

        printf "%s\n" "${package}"
    done < <(brew_packages)
}

print_dependency_guidance() {
    log_error "missing build dependencies"
    printf "Package list: %s\n" "${MACOS_PACKAGES_FILE}" >&2
    printf "Install the packages listed above with Homebrew or equivalents.\n" >&2
    printf "If cargo and rustc are already installed, rust can be omitted.\n" >&2
    printf "Homebrew command:\n" >&2
    printf "    %s install " "${BREW_BIN:-brew}" >&2
    brew_install_packages | tr "\n" " " >&2
    printf "\n" >&2
}

confirm_brew_install() {
    local reply

    if [[ "${INSTALL_DEPS}" == "yes" ]]; then
        return 0
    fi

    if [[ "${INSTALL_DEPS}" == "no" ]]; then
        return 1
    fi

    if [[ ! -t 0 ]]; then
        return 1
    fi

    printf "Install missing packages with %s? [y/N] " "${BREW_BIN}" >&2
    read -r reply
    case "${reply}" in
        y | Y | yes | YES)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

configure_homebrew_environment() {
    local gettext_prefix
    local libarchive_prefix
    local openssl_prefix

    if ! detect_brew; then
        print_dependency_guidance
        exit 1
    fi

    log_status "Detected" "Homebrew: ${BREW_BIN}"
    log_status "Detected" "Homebrew prefix: ${BREW_PREFIX}"

    gettext_prefix="$("${BREW_BIN}" --prefix gettext 2>/dev/null || true)"
    libarchive_prefix="$("${BREW_BIN}" --prefix libarchive 2>/dev/null || true)"
    openssl_prefix="$("${BREW_BIN}" --prefix openssl@3 2>/dev/null || true)"

    export PATH="${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:${PATH}"
    export PKG_CONFIG_PATH="${BREW_PREFIX}/lib/pkgconfig"
    export PKG_CONFIG_PATH="${PKG_CONFIG_PATH}:${BREW_PREFIX}/share/pkgconfig"
    export ACLOCAL_PATH="${BREW_PREFIX}/share/aclocal:${ACLOCAL_PATH:-}"
    export LIBRARY_PATH="${BREW_PREFIX}/lib:${LIBRARY_PATH:-}"
    export CPATH="${BREW_PREFIX}/include:${CPATH:-}"

    if [[ -n "${gettext_prefix}" ]]; then
        export PATH="${gettext_prefix}/bin:${PATH}"
        export PKG_CONFIG_PATH="${gettext_prefix}/lib/pkgconfig:${PKG_CONFIG_PATH}"
    fi

    if [[ -n "${libarchive_prefix}" ]]; then
        export PKG_CONFIG_PATH="${libarchive_prefix}/lib/pkgconfig:${PKG_CONFIG_PATH}"
        export LIBRARY_PATH="${libarchive_prefix}/lib:${LIBRARY_PATH}"
        export CPATH="${libarchive_prefix}/include:${CPATH}"
    fi

    if [[ -n "${openssl_prefix}" ]]; then
        export PKG_CONFIG_PATH="${openssl_prefix}/lib/pkgconfig:${PKG_CONFIG_PATH}"
        export LIBRARY_PATH="${openssl_prefix}/lib:${LIBRARY_PATH}"
        export CPATH="${openssl_prefix}/include:${CPATH}"
    fi
}

ensure_brew_packages() {
    local missing=()
    local package

    while IFS= read -r package; do
        if [[ -z "${package}" ]]; then
            continue
        fi

        if [[ "${package}" == "rust" ]] && rust_toolchain_available; then
            log_status "Fresh" "Rust toolchain: $(command -v cargo)"
            continue
        fi

        if [[ "${DRY_RUN}" == "1" ]]; then
            missing+=("${package}")
            continue
        fi

        if ! "${BREW_BIN}" list --formula "${package}" >/dev/null 2>&1; then
            missing+=("${package}")
        fi
    done < <(brew_packages)

    if [[ "${#missing[@]}" -eq 0 ]]; then
        log_status "Finished" "all Homebrew packages are installed"
        return
    fi

    log_warn "Missing" "Homebrew packages: ${missing[*]}"
    if [[ "${DRY_RUN}" == "1" ]]; then
        run "${BREW_BIN}" install "${missing[@]}"
        return
    fi

    if confirm_brew_install; then
        run "${BREW_BIN}" install "${missing[@]}"
    else
        print_dependency_guidance
        exit 1
    fi
}

require_command() {
    local command_name="$1"

    if ! command -v "${command_name}" >/dev/null 2>&1; then
        if [[ "${DRY_RUN}" == "1" ]]; then
            log_warn "Missing" "required command is not available: ${command_name}"
            return
        fi

        log_error "missing required command: ${command_name}"
        exit 1
    fi
}

check_required_tools() {
    if ! host_is_macos; then
        log_error "this script must run on macOS"
        exit 1
    fi

    configure_homebrew_environment
    ensure_brew_packages
    configure_homebrew_environment
    configure_rust_toolchain

    require_command meson
    require_command ninja
    require_command cargo
    require_command rustc
    require_command pkg-config
    require_command glib-compile-schemas
    require_command xattr
    if [[ "${BUNDLE_PATCHED_MPV}" == "1" ]]; then
        require_command install_name_tool
    fi
}

mpv_deps_dir() {
    printf "%s/deps/mpv\n" "${BUILD_DIR}"
}

mpv_source_parent_dir() {
    printf "%s/source\n" "$(mpv_deps_dir)"
}

mpv_build_dir() {
    printf "%s/build\n" "$(mpv_deps_dir)"
}

mpv_prefix_dir() {
    printf "%s/prefix\n" "$(mpv_deps_dir)"
}

find_mpv_source_dir() {
    local source_parent
    source_parent="$(mpv_source_parent_dir)"

    if [[ ! -d "${source_parent}" ]]; then
        return
    fi

    find "${source_parent}" \
        -maxdepth 1 \
        -type d \
        -name "mpv-*" \
        -print \
        | sort \
        | head -n 1
}

ensure_mpv_source() {
    local source_dir
    local source_parent

    source_dir="$(find_mpv_source_dir)"
    if [[ -n "${source_dir}" && -f "${source_dir}/meson.build" ]]; then
        log_status "Fresh" "mpv source: ${source_dir}"
        return
    fi

    source_parent="$(mpv_source_parent_dir)"
    run mkdir -p "${source_parent}"
    run "${BREW_BIN}" unpack --patch mpv --destdir "${source_parent}"
}

build_bundled_mpv() {
    local build_dir
    local config_stamp
    local expected_config
    local prefix_dir
    local source_dir

    build_dir="$(mpv_build_dir)"
    prefix_dir="$(mpv_prefix_dir)"
    config_stamp="${prefix_dir}/.tsukimi-mpv-build-options"
    expected_config="$(
        printf "%s\n" \
            "build-date=false" \
            "html-build=disabled" \
            "javascript=enabled" \
            "libmpv=true" \
            "lua=luajit" \
            "libarchive=enabled" \
            "uchardet=enabled" \
            "gl=enabled" \
            "gl-cocoa=enabled" \
            "cocoa=enabled" \
            "vulkan=enabled" \
            "swift-build=enabled" \
            "macos-cocoa-cb=enabled" \
            "videotoolbox-pl=enabled" \
            "macos-media-player=disabled"
    )"

    if [[ -f "${prefix_dir}/lib/libmpv.2.dylib" &&
          -f "${prefix_dir}/lib/pkgconfig/mpv.pc" &&
          -f "${config_stamp}" &&
          "$(cat "${config_stamp}")" == "${expected_config}" ]]; then
        log_status "Fresh" "bundled libmpv"
        return
    fi

    source_dir="$(find_mpv_source_dir)"
    if [[ -z "${source_dir}" || ! -f "${source_dir}/meson.build" ]]; then
        log_error "mpv source is missing after brew unpack"
        exit 1
    fi

    if [[ -d "${build_dir}" || -d "${prefix_dir}" ]]; then
        run rm -rf "${build_dir}" "${prefix_dir}"
    fi

    if [[ ! -f "${build_dir}/build.ninja" ]]; then
        run meson setup "${build_dir}" "${source_dir}" \
            --prefix "${prefix_dir}" \
            --libdir lib \
            --buildtype release \
            -Dbuild-date=false \
            -Dhtml-build=disabled \
            -Djavascript=enabled \
            -Dlibmpv=true \
            -Dlua=luajit \
            -Dlibarchive=enabled \
            -Duchardet=enabled \
            -Dgl=enabled \
            -Dgl-cocoa=enabled \
            -Dcocoa=enabled \
            -Dvulkan=enabled \
            -Dswift-build=enabled \
            -Dmacos-cocoa-cb=enabled \
            -Dvideotoolbox-pl=enabled \
            -Dmacos-media-player=disabled
    else
        run meson setup "${build_dir}" "${source_dir}" \
            --prefix "${prefix_dir}" \
            --libdir lib \
            --buildtype release \
            -Dbuild-date=false \
            -Dhtml-build=disabled \
            -Djavascript=enabled \
            -Dlibmpv=true \
            -Dlua=luajit \
            -Dlibarchive=enabled \
            -Duchardet=enabled \
            -Dgl=enabled \
            -Dgl-cocoa=enabled \
            -Dcocoa=enabled \
            -Dvulkan=enabled \
            -Dswift-build=enabled \
            -Dmacos-cocoa-cb=enabled \
            -Dvideotoolbox-pl=enabled \
            -Dmacos-media-player=disabled \
            --reconfigure
    fi

    run meson compile -C "${build_dir}"
    run meson install -C "${build_dir}"
    if [[ "${DRY_RUN}" == "0" ]]; then
        printf "%s" "${expected_config}" >"${config_stamp}"
    fi
}

prepare_mpv_dependency() {
    local prefix_dir

    if [[ "${BUNDLE_PATCHED_MPV}" != "1" ]]; then
        log_warn "Skipped" "bundled mpv disabled by --system-mpv"
        return
    fi

    ensure_mpv_source
    if [[ "${DRY_RUN}" == "1" ]]; then
        return
    fi

    build_bundled_mpv

    prefix_dir="$(mpv_prefix_dir)"
    export PKG_CONFIG_PATH="${prefix_dir}/lib/pkgconfig:${PKG_CONFIG_PATH}"
    export LIBRARY_PATH="${prefix_dir}/lib:${LIBRARY_PATH:-}"
    export DYLD_LIBRARY_PATH="${prefix_dir}/lib:${DYLD_LIBRARY_PATH:-}"
    log_status "Detected" "bundled libmpv: ${prefix_dir}/lib/libmpv.2.dylib"
}

state_file() {
    printf "%s/.build-macos-app.state\n" "${BUILD_DIR}"
}

state_fingerprint_file() {
    printf "%s/.build-macos-app.fingerprint\n" "${BUILD_DIR}"
}

source_fingerprint() {
    if git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        {
            git -C "${REPO_ROOT}" rev-parse HEAD
            git -C "${REPO_ROOT}" diff --binary -- .
            while IFS= read -r path; do
                if [[ -f "${REPO_ROOT}/${path}" ]]; then
                    shasum -a 256 "${REPO_ROOT}/${path}"
                fi
            done < <(git -C "${REPO_ROOT}" ls-files --others --exclude-standard)
        } | shasum -a 256 | awk '{ print $1 }'
        return
    fi

    find "${REPO_ROOT}/src" \
        "${REPO_ROOT}/resources" \
        "${REPO_ROOT}/po" \
        "${REPO_ROOT}/share/macos" \
        "${REPO_ROOT}/scripts" \
        "${REPO_ROOT}/Cargo.toml" \
        "${REPO_ROOT}/Cargo.lock" \
        "${REPO_ROOT}/meson.build" \
        -type f \
        -print0 \
        | sort -z \
        | xargs -0 shasum -a 256 \
        | shasum -a 256 \
        | awk '{ print $1 }'
}

current_fingerprint() {
    printf "bundle_layout_version=%s\n" "4"
    printf "build_dir=%s\noutput_dir=%s\nprofile=%s\n" \
        "${BUILD_DIR}" \
        "${OUTPUT_DIR}" \
        "${PROFILE}"
    printf "skip_codesign=%s\nsign_identity=%s\n" \
        "${SKIP_CODESIGN}" \
        "${SIGN_IDENTITY}"
    printf "bundle_patched_mpv=%s\n" "${BUNDLE_PATCHED_MPV}"
    printf "source_fingerprint=%s\n" "$(source_fingerprint)"
}

prepare_state() {
    local fingerprint_file
    fingerprint_file="$(state_fingerprint_file)"

    if [[ "${CLEAN}" == "1" ]]; then
        run rm -rf "${BUILD_DIR}" "${OUTPUT_DIR}"
    fi

    if [[ "${DRY_RUN}" == "1" ]]; then
        return
    fi

    mkdir -p "${BUILD_DIR}"

    if [[ -f "${fingerprint_file}" ]]; then
        if [[ "$(cat "${fingerprint_file}")" != "$(current_fingerprint)" ]]; then
            rm -f "$(state_file)"
        fi
    fi

    current_fingerprint >"${fingerprint_file}"
}

last_completed_step() {
    local file
    file="$(state_file)"

    if [[ -f "${file}" ]]; then
        cat "${file}"
    else
        printf "%s\n" "-1"
    fi
}

mark_step_completed() {
    local step_index="$1"

    if [[ "${DRY_RUN}" == "0" ]]; then
        printf "%s\n" "${step_index}" >"$(state_file)"
    fi
}

run_step() {
    local step_index="$1"
    local step_name="$2"
    local step_function="$3"
    local completed

    completed="$(last_completed_step)"
    if [[ "${completed}" -ge "${step_index}" ]]; then
        log_status "Fresh" "${step_name}"
        return
    fi

    log_status "Compiling" "${step_name}"
    "${step_function}"
    mark_step_completed "${step_index}"
}

setup_meson() {
    local prefix_dir
    local rust_target="${PROFILE}"

    prefix_dir="$(bundle_resources_dir)"

    if [[ ! -f "${BUILD_DIR}/build.ninja" ]]; then
        run meson setup "${BUILD_DIR}" \
            --prefix "${prefix_dir}" \
            -Drust-target="${rust_target}" \
            -Dmacos-bundle=true \
            --buildtype "${PROFILE}"
    else
        if ! run meson setup "${BUILD_DIR}" \
            --prefix "${prefix_dir}" \
            -Drust-target="${rust_target}" \
            -Dmacos-bundle=true \
            --buildtype "${PROFILE}" \
            --reconfigure; then
            reset_meson_build_dir_preserving_deps
            run meson setup "${BUILD_DIR}" \
                --prefix "${prefix_dir}" \
                -Drust-target="${rust_target}" \
                -Dmacos-bundle=true \
                --buildtype "${PROFILE}"
        fi
    fi
}

reset_meson_build_dir_preserving_deps() {
    local entry

    log_warn "Stale" "Meson build metadata is incompatible; rebuilding main build directory"
    if [[ "${DRY_RUN}" == "1" ]]; then
        log_status "Running" "clean ${BUILD_DIR} except deps"
        return
    fi

    while IFS= read -r entry; do
        rm -rf "${entry}"
    done < <(
        find "${BUILD_DIR}" \
            -mindepth 1 \
            -maxdepth 1 \
            ! -name deps \
            -print
    )
}

compile_project() {
    run meson compile -C "${BUILD_DIR}"
}

install_project() {
    run meson install -C "${BUILD_DIR}"
}

app_dir() {
    printf "%s/%s.app\n" "${OUTPUT_DIR}" "${APP_NAME}"
}

bundle_contents_dir() {
    printf "%s/Contents\n" "$(app_dir)"
}

bundle_macos_dir() {
    printf "%s/MacOS\n" "$(bundle_contents_dir)"
}

bundle_resources_dir() {
    printf "%s/Resources\n" "$(bundle_contents_dir)"
}

create_bundle_layout() {
    local app
    local contents
    local macos
    local resources

    app="$(app_dir)"
    contents="$(bundle_contents_dir)"
    macos="$(bundle_macos_dir)"
    resources="$(bundle_resources_dir)"

    run rm -rf "${app}"
    run mkdir -p "${macos}" "${resources}"
    run cp "${REPO_ROOT}/share/macos/Info.plist" "${contents}/Info.plist"
    copy_app_icon "${resources}"
}

copy_app_icon() {
    local resources="$1"
    local icns="${REPO_ROOT}/share/macos/AppIcon.icns"

    run cp "${icns}" "${resources}/AppIcon.icns"
}

copy_installed_executable() {
    local build_output
    local prefix_dir
    local macos

    prefix_dir="$(bundle_resources_dir)"
    macos="$(bundle_macos_dir)"
    build_output="${BUILD_DIR}/src/${EXECUTABLE_NAME}"

    if [[ -f "${prefix_dir}/bin/${EXECUTABLE_NAME}" ]]; then
        run cp "${prefix_dir}/bin/${EXECUTABLE_NAME}" "${macos}/${EXECUTABLE_NAME}-bin"
    else
        run cp "${build_output}" "${macos}/${EXECUTABLE_NAME}-bin"
    fi
    run chmod +x "${macos}/${EXECUTABLE_NAME}-bin"
}

patch_install_name() {
    local binary="$1"
    local old_name="$2"
    local new_name="$3"

    log_status "Running" "install_name_tool -change ${old_name} ${new_name} ${binary}"
    install_name_tool -change "${old_name}" "${new_name}" "${binary}" 2>/dev/null || true
}

add_bundle_library_rpath() {
    local binary="$1"
    local rpath="@executable_path/../Resources/lib"

    if otool -l "${binary}" | grep -F "${rpath}" >/dev/null; then
        log_status "Fresh" "bundle library rpath"
        return
    fi

    run install_name_tool -add_rpath "${rpath}" "${binary}"
}

bundle_patched_mpv() {
    local binary
    local lib_dir
    local mpv_lib
    local prefix_dir
    local target_lib

    if [[ "${BUNDLE_PATCHED_MPV}" != "1" ]]; then
        log_warn "Skipped" "bundled mpv disabled by --system-mpv"
        return
    fi

    prefix_dir="$(mpv_prefix_dir)"
    mpv_lib="${prefix_dir}/lib/libmpv.2.dylib"
    lib_dir="$(bundle_resources_dir)/lib"
    target_lib="${lib_dir}/libmpv.2.dylib"
    binary="$(bundle_macos_dir)/${EXECUTABLE_NAME}-bin"

    run mkdir -p "${lib_dir}"
    run cp "${mpv_lib}" "${target_lib}"
    run chmod u+w "${target_lib}" "${binary}"

    if [[ "${DRY_RUN}" == "1" ]]; then
        return
    fi

    run install_name_tool -id "@rpath/libmpv.2.dylib" "${target_lib}"
    add_bundle_library_rpath "${binary}"
    patch_install_name \
        "${binary}" \
        "${prefix_dir}/lib/libmpv.2.dylib" \
        "@rpath/libmpv.2.dylib"
    patch_install_name \
        "${binary}" \
        "${BREW_PREFIX}/opt/mpv/lib/libmpv.2.dylib" \
        "@rpath/libmpv.2.dylib"
    patch_install_name \
        "${binary}" \
        "${BREW_PREFIX}/lib/libmpv.2.dylib" \
        "@rpath/libmpv.2.dylib"
}

write_launcher() {
    local launcher

    launcher="$(bundle_macos_dir)/${EXECUTABLE_NAME}"
    # Keep launcher variables literal so they expand inside the generated file.
    # shellcheck disable=SC2016
    write_file "${launcher}" \
        '#!/usr/bin/env bash' \
        '' \
        'set -euo pipefail' \
        '' \
        'APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"' \
        'CONTENTS_DIR="${APP_ROOT}/Contents"' \
        'RESOURCES_DIR="${CONTENTS_DIR}/Resources"' \
        'BINARY="${CONTENTS_DIR}/MacOS/tsukimi-bin"' \
        '' \
        'host_arch() {' \
        '    uname -m' \
        '}' \
        '' \
        'brew_binary_candidates() {' \
        '    if [[ -n "${TSUKIMI_BREW:-}" ]]; then' \
        '        printf "%s\n" "${TSUKIMI_BREW}"' \
        '    fi' \
        '' \
        '    if [[ "$(host_arch)" == "arm64" ]]; then' \
        '        printf "%s\n" /opt/homebrew/bin/brew' \
        '        printf "%s\n" /usr/local/bin/brew' \
        '    else' \
        '        printf "%s\n" /usr/local/bin/brew' \
        '        printf "%s\n" /opt/homebrew/bin/brew' \
        '    fi' \
        '' \
        '    if command -v brew >/dev/null 2>&1; then' \
        '        command -v brew' \
        '    fi' \
        '}' \
        '' \
        'detect_brew_prefix() {' \
        '    local candidate' \
        '' \
        '    while IFS= read -r candidate; do' \
        '        if [[ -x "${candidate}" ]]; then' \
        '            "${candidate}" --prefix' \
        '            return' \
        '        fi' \
        '    done < <(brew_binary_candidates)' \
        '' \
        '    if [[ "$(host_arch)" == "arm64" ]]; then' \
        '        printf "%s\n" /opt/homebrew' \
        '    else' \
        '        printf "%s\n" /usr/local' \
        '    fi' \
        '}' \
        '' \
        'BREW_PREFIX="${TSUKIMI_BREW_PREFIX:-$(detect_brew_prefix)}"' \
        'BUNDLE_SHARE="${RESOURCES_DIR}/share"' \
        'BUNDLE_LIB="${RESOURCES_DIR}/lib"' \
        '' \
        'export GSETTINGS_SCHEMA_DIR="${BUNDLE_SHARE}/glib-2.0/schemas"' \
        'export XDG_DATA_DIRS="${BUNDLE_SHARE}:${BREW_PREFIX}/share:${XDG_DATA_DIRS:-}"' \
        'export GTK_DATA_PREFIX="${BREW_PREFIX}"' \
        'DYLD_PATH="${BUNDLE_LIB}:${BREW_PREFIX}/lib:${DYLD_LIBRARY_PATH:-}"' \
        'TYPELIB_PATH="${BREW_PREFIX}/lib/girepository-1.0:${GI_TYPELIB_PATH:-}"' \
        'GST_PATH="${BREW_PREFIX}/lib/gstreamer-1.0:${GST_PLUGIN_SYSTEM_PATH:-}"' \
        'export DYLD_LIBRARY_PATH="${DYLD_PATH}"' \
        'export GI_TYPELIB_PATH="${TYPELIB_PATH}"' \
        'export GST_PLUGIN_SYSTEM_PATH="${GST_PATH}"' \
        '' \
        'exec "${BINARY}" "$@"'

    if [[ "${DRY_RUN}" == "0" ]]; then
        chmod +x "${launcher}"
    fi
}

compile_bundle_schemas() {
    local schema_dir

    schema_dir="$(bundle_resources_dir)/share/glib-2.0/schemas"
    if [[ -d "${schema_dir}" ]]; then
        run glib-compile-schemas "${schema_dir}"
    elif [[ "${DRY_RUN}" == "1" ]]; then
        log_warn "Skipped" "schema directory does not exist: ${schema_dir}"
    else
        log_error "schema directory does not exist: ${schema_dir}"
        exit 1
    fi
}

require_bundle_file() {
    local path="$1"
    local description="$2"

    if [[ -f "${path}" ]]; then
        log_status "Fresh" "${description}"
        return
    fi

    log_error "missing ${description}: ${path}"
    exit 1
}

require_bundle_absent() {
    local path="$1"
    local description="$2"

    if [[ ! -e "${path}" ]]; then
        log_status "Fresh" "${description} omitted"
        return
    fi

    log_error "unexpected ${description}: ${path}"
    exit 1
}

validate_bundle_contents() {
    local contents
    local macos
    local resources

    contents="$(bundle_contents_dir)"
    macos="$(bundle_macos_dir)"
    resources="$(bundle_resources_dir)"

    require_bundle_file "${contents}/Info.plist" "Info.plist"
    require_bundle_file "${macos}/${EXECUTABLE_NAME}" "launcher"
    require_bundle_file "${macos}/${EXECUTABLE_NAME}-bin" "application binary"
    require_bundle_file "${resources}/AppIcon.icns" "application icon"
    require_bundle_file "${resources}/share/tsukimi/tsukimi.gresource" "GResource bundle"
    require_bundle_file \
        "${resources}/share/glib-2.0/schemas/gschemas.compiled" \
        "compiled GSettings schemas"
    require_bundle_absent "${resources}/bin" "Resources/bin"
    require_bundle_absent "${resources}/share/applications" "Linux desktop files"
    require_bundle_absent "${resources}/share/metainfo" "AppStream metadata"
    require_bundle_absent "${resources}/share/icons" "Linux icon theme cache"
    if [[ "${BUNDLE_PATCHED_MPV}" == "1" ]]; then
        require_bundle_file "${resources}/lib/libmpv.2.dylib" "bundled libmpv"
    fi
}

codesign_bundle() {
    local app

    if [[ "${SKIP_CODESIGN}" == "1" ]]; then
        log_warn "Skipped" "codesign disabled by --skip-codesign"
        return
    fi

    if ! command -v codesign >/dev/null 2>&1; then
        log_warn "Skipped" "codesign command is not available"
        return
    fi

    if [[ "${SIGN_IDENTITY}" != "-" ]]; then
        validate_codesign_identity "${SIGN_IDENTITY}"
    fi

    app="$(app_dir)"
    run codesign --force --deep --sign "${SIGN_IDENTITY}" "${app}"
}

validate_codesign_identity() {
    local identity="$1"

    if [[ "${DRY_RUN}" == "1" ]]; then
        return
    fi

    if ! command -v security >/dev/null 2>&1; then
        log_error "security command is required for named codesign identity"
        exit 1
    fi

    if security find-identity -v -p codesigning \
        | grep -F "\"${identity}\"" >/dev/null
    then
        return
    fi

    log_error "codesign identity not found: ${identity}"
    printf "Create a self-signed code signing certificate in Keychain Access:\n" >&2
    printf "    1. Open Keychain Access\n" >&2
    printf "    2. Certificate Assistant > Create a Certificate\n" >&2
    printf "    3. Name: %s\n" "${identity}" >&2
    printf "    4. Identity Type: Self Signed Root\n" >&2
    printf "    5. Certificate Type: Code Signing\n" >&2
    printf "Then rerun this script with --self-sign.\n" >&2
    exit 1
}

clear_quarantine_attribute() {
    local app

    app="$(app_dir)"
    log_status "Running" "xattr -dr com.apple.quarantine ${app}"
    if [[ "${DRY_RUN}" == "0" ]]; then
        xattr -dr com.apple.quarantine "${app}" 2>/dev/null || true
    fi
}

print_result() {
    log_status "Finished" "macOS app bundle: $(app_dir)"
}

main() {
    parse_args "$@"
    validate_options
    check_required_tools
    prepare_state
    prepare_mpv_dependency

    run_step 0 "create app bundle layout" create_bundle_layout
    run_step 1 "configure Meson" setup_meson
    run_step 2 "compile project" compile_project
    run_step 3 "install project" install_project
    run_step 4 "copy installed executable" copy_installed_executable
    run_step 5 "bundle patched libmpv" bundle_patched_mpv
    run_step 6 "write launcher" write_launcher
    run_step 7 "compile GSettings schemas" compile_bundle_schemas
    run_step 8 "validate bundle contents" validate_bundle_contents
    run_step 9 "codesign bundle" codesign_bundle
    run_step 10 "clear quarantine attribute" clear_quarantine_attribute

    print_result
}

main "$@"
