#!/usr/bin/env bash
# ============================================================
# Script Name: install-kwtype-fedora.sh
# Version    : v0.6.1
# Author     : Ruhani Rabin (https://www.ruhanirabin.com)
# Node       : N/A
# Created    : 2026-07-02
# Updated    : 2026-08-23
#
# Description:
# Builds and installs KWtype on Fedora for KDE Plasma Wayland.
# KWtype provides native text injection through KWin's Fake
# Input protocol and allows Handy to use Direct paste reliably.
#
# Dependencies:
# - Fedora Linux with dnf
# - KDE Plasma / KWin Wayland at runtime
# - sudo
# - Internet access to GitHub
#
# Usage:
# curl -fsSL <raw-install-url> | bash
#
# Or:
# chmod +x install-kwtype-fedora.sh
# ./install-kwtype-fedora.sh
#
# Notes:
# - Installs KWtype into ~/.local/bin.
# - Does not install or configure ydotool.
# - Does not modify shell profiles or PATH.
# - KWin may request Fake Input permission on first KWtype use.
# - Logs are stored under /var/log/kwtype-installer/ for 7 days.
#
# Changelog:
# v0.6.1 - Added explicit curl-pipe-bash usage guidance and
#          clearer protection against running via sudo bash.
# v0.6.0 - Hardened Fedora checks, logging, locking, cleanup,
#          error reporting, dependency validation, and corrected
#          Handy Direct-mode guidance.
# v0.5.1 - Initial structured version
# ============================================================

set -Eeuo pipefail

readonly SCRIPT_NAME="install-kwtype-fedora"
readonly SCRIPT_VERSION="v0.6.1"
readonly REPO_URL="https://github.com/Sporif/KWtype.git"
readonly INSTALL_PREFIX="${HOME}/.local"
readonly KWTYPE_BIN="${INSTALL_PREFIX}/bin/kwtype"
readonly LOG_DIR="/var/log/kwtype-installer"
readonly LOG_RETENTION_DAYS=7
readonly RUN_ID="$(date '+%Y%m%d-%H%M%S')"
readonly LOG_FILE="${LOG_DIR}/install-${RUN_ID}.log"
readonly LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/${SCRIPT_NAME}-${UID}.lock"

BUILD_DIR=""
KWTYPE_COMMIT=""
LOGGING_READY=false

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*"
}

warn() {
    log "WARNING: $*" >&2
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

cleanup() {
    local exit_code=$?

    if [[ -n "${BUILD_DIR}" && -d "${BUILD_DIR}" ]]; then
        rm -rf -- "${BUILD_DIR}" || true
    fi

    if [[ "${LOGGING_READY}" == "true" ]]; then
        log "Finished with exit code ${exit_code}."
    fi

    exit "${exit_code}"
}

on_error() {
    local exit_code=$?
    local line_no=$1
    local command=$2

    printf '%s ERROR: command failed at line %s (exit %s): %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S %z')" \
        "${line_no}" \
        "${exit_code}" \
        "${command}" >&2

    return "${exit_code}"
}

trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap cleanup EXIT

require_command() {
    local command_name=$1

    command -v "${command_name}" >/dev/null 2>&1 \
        || die "Required command not found: ${command_name}"
}

check_platform() {
    [[ -r /etc/os-release ]] || die "/etc/os-release is unavailable."

    # shellcheck disable=SC1091
    source /etc/os-release

    [[ "${ID:-}" == "fedora" ]] \
        || die "Unsupported distribution: ${PRETTY_NAME:-unknown}. This installer targets Fedora."

    if [[ "${XDG_SESSION_TYPE:-}" != "wayland" ]]; then
        warn "Current session is '${XDG_SESSION_TYPE:-unknown}', not Wayland."
        warn "KWtype can still be installed, but its intended runtime is KDE Plasma Wayland."
    fi

    case "${XDG_CURRENT_DESKTOP:-}" in
        *KDE*|*Plasma*)
            ;;
        *)
            warn "KDE Plasma was not detected in XDG_CURRENT_DESKTOP='${XDG_CURRENT_DESKTOP:-unset}'."
            warn "KWtype requires KWin's KDE Fake Input protocol at runtime."
            ;;
    esac
}

setup_logging() {
    local current_user
    local current_group

    current_user="$(id -un)"
    current_group="$(id -gn)"

    sudo install -d -m 0755 "${LOG_DIR}"
    sudo touch "${LOG_FILE}"
    sudo chown "${current_user}:${current_group}" "${LOG_FILE}"
    chmod 0644 "${LOG_FILE}"

    exec > >(tee -a "${LOG_FILE}") 2>&1
    LOGGING_READY=true

    if ! sudo find "${LOG_DIR}" \
        -type f \
        -name 'install-*.log' \
        -mtime "+${LOG_RETENTION_DAYS}" \
        -delete; then
        warn "Could not remove expired installer logs."
    fi
}

install_dependencies() {
    local packages=(
        git
        gcc-c++
        meson
        ninja-build
        pkgconf-pkg-config
        qt6-qtbase-devel
        kwayland-devel
        libxkbcommon-devel
        wayland-devel
    )

    log "Installing Fedora build dependencies."
    sudo dnf install -y "${packages[@]}"

    local commands=(
        git
        g++
        meson
        ninja
        pkg-config
    )

    local command_name
    for command_name in "${commands[@]}"; do
        require_command "${command_name}"
    done

    local pkg_modules=(
        Qt6Core
        Qt6DBus
        KWaylandClient
        wayland-client
        xkbcommon
    )

    local module
    for module in "${pkg_modules[@]}"; do
        if ! pkg-config --exists "${module}"; then
            die "Required pkg-config module is unavailable after dependency installation: ${module}"
        fi
    done
}

build_and_install() {
    BUILD_DIR="$(mktemp -d)"
    log "Temporary build directory: ${BUILD_DIR}"

    log "Cloning KWtype from ${REPO_URL}"
    git clone --depth 1 "${REPO_URL}" "${BUILD_DIR}/KWtype"

    cd "${BUILD_DIR}/KWtype"
    KWTYPE_COMMIT="$(git rev-parse HEAD)"
    log "Building KWtype commit: ${KWTYPE_COMMIT}"

    log "Configuring KWtype with Meson."
    meson setup \
        --buildtype=release \
        --prefix="${INSTALL_PREFIX}" \
        build

    log "Compiling KWtype."
    meson compile -C build

    log "Installing KWtype to ${INSTALL_PREFIX}"
    meson install -C build
}

verify_installation() {
    [[ -f "${KWTYPE_BIN}" ]] \
        || die "Installation completed but ${KWTYPE_BIN} does not exist."

    [[ -x "${KWTYPE_BIN}" ]] \
        || die "Installation completed but ${KWTYPE_BIN} is not executable."

    log "Verified installed binary: ${KWTYPE_BIN}"

    if [[ ":${PATH}:" != *":${INSTALL_PREFIX}/bin:"* ]]; then
        warn "${INSTALL_PREFIX}/bin is not in the current PATH."
        warn "Handy may not auto-detect kwtype until ~/.local/bin is available in its login environment."
    elif ! command -v kwtype >/dev/null 2>&1; then
        warn "kwtype exists but command lookup did not find it."
    else
        log "kwtype is available in PATH as: $(command -v kwtype)"
    fi
}

print_next_steps() {
    cat <<EOF

============================================================
KWtype installation successful
============================================================
Version:       ${SCRIPT_VERSION}
Commit:        ${KWTYPE_COMMIT}
Binary:        ${KWTYPE_BIN}
Log:           ${LOG_FILE}

Test:
  sleep 3; "${KWTYPE_BIN}" "KWtype works on KDE Wayland"

After starting the test, focus a text field during the 3-second
delay. KWin may request Fake Input permission on first use.

Handy:
  Paste Method:      Direct
  Overlay Position:  None

On KDE Wayland, current Handy builds can detect KWtype and log:
  Using kwtype for direct text input on KDE Wayland

No ydotool or ydotoold installation is required when KWtype is
detected and Direct paste works.
============================================================
EOF
}

main() {
    if [[ "${EUID}" -eq 0 ]]; then
        cat >&2 <<'EOF'
ERROR: Do not run this installer as root or with "sudo bash".

Run it as your normal desktop user instead:

  curl -fsSL <raw-install-url> | bash

Or, if you downloaded the script first:

  chmod +x install-kwtype-fedora.sh
  ./install-kwtype-fedora.sh

The installer requests sudo itself only for system-level changes such
as installing Fedora packages and creating the log directory.
EOF
        exit 1
    fi

    require_command dnf
    require_command sudo
    require_command flock
        require_command tee

    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        die "Another ${SCRIPT_NAME} process is already running for this user."
    fi

    sudo -v
    setup_logging

    log "${SCRIPT_NAME} ${SCRIPT_VERSION} started."
    check_platform
    install_dependencies
    build_and_install
    verify_installation
    print_next_steps
}

main "$@"
