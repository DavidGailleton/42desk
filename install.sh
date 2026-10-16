#!/usr/bin/env bash
# Fresh base install of a JuNest environment for 42 computers.
#
# Usage: ./install.sh [--rootfs PATH] [--desktop ID|none] [--yes]
#        ./install.sh --step desktop [--desktop ID|none]
#   --rootfs PATH     where to create the rootfs (otherwise asked)
#   --desktop ID      desktop to set up (i3, bspwm, awesome, xfce or none; otherwise asked)
#   --step desktop    only (re)run that step on the existing install
#   -y, --yes         answer yes / take defaults for every question
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/cleanup.sh
. "$REPO_DIR/lib/cleanup.sh"
# shellcheck source=lib/junest.sh
. "$REPO_DIR/lib/junest.sh"
# shellcheck source=lib/guest.sh
. "$REPO_DIR/lib/guest.sh"
# shellcheck source=lib/desktop.sh
. "$REPO_DIR/lib/desktop.sh"

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

ROOTFS="" DESKTOP_CHOICE="" STEP=""
while (($#)); do
    case "$1" in
        --rootfs) ROOTFS=${2:?--rootfs needs a path}; shift 2 ;;
        --desktop) DESKTOP_CHOICE=${2:?--desktop needs an id}; shift 2 ;;
        --step) STEP=${2:?--step needs a name}; shift 2 ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage ;;
        *) warn "unknown option: $1"; usage 1 ;;
    esac
done

preflight() {
    local cmd
    ((EUID != 0)) || die "run this as your normal user, not root"
    [[ -z ${JUNEST_ENV:-} ]] || die "run this from the host, not inside JuNest"
    for cmd in git curl readelf flock unshare; do
        command -v "$cmd" >/dev/null || die "missing host command: $cmd"
    done
    unshare --user --map-root-user true 2>/dev/null ||
        die "unprivileged user namespaces are disabled, JuNest ns mode cannot work"
    make_tmp_root
    (($(free_gib "$TMP_ROOT") >= 3)) || die "less than 3 GiB free in /tmp"
}

choose_rootfs() {
    local choice
    if [[ -z $ROOTFS ]]; then
        choice=$(ask_menu "JuNest location" \
            "Where should the JuNest rootfs live?" home \
            home    "$DEFAULT_ROOTFS  (kept when changing computer, uses home quota)" \
            goinfre "$GOINFRE/junest  (fast, no quota, this computer only)" \
            custom  "Another path") || die "aborted"
        case "$choice" in
            home)    ROOTFS=$DEFAULT_ROOTFS ;;
            goinfre) ROOTFS=$GOINFRE/junest ;;
            custom)  ROOTFS=$(ask_input "JuNest location" "Absolute path of the rootfs:" "$DEFAULT_ROOTFS") ||
                         die "aborted" ;;
            *)       die "unknown choice: $choice" ;;
        esac
    fi
    [[ $ROOTFS == /* ]] || die "rootfs path must be absolute: $ROOTFS"
    [[ $ROOTFS != *[[:space:]]* ]] || die "rootfs path must not contain spaces: $ROOTFS"
    ROOTFS=$(realpath -m "$ROOTFS")
    case "$ROOTFS" in
        / | "$HOME" | /goinfre | /sgoinfre) die "refusing rootfs path: $ROOTFS" ;;
        /tmp | /tmp/*) die "/tmp is wiped at reboot, pick another rootfs path" ;;
    esac
    log "rootfs: $ROOTFS"
}

summary() {
    log "done"
    printf '  rootfs:      %s (%s)\n' "$ROOTFS" "$(du -sh "$ROOTFS" 2>/dev/null | cut -f1)"
    printf '  home free:   %s GiB\n' "$(free_gib "$HOME")"
    printf '  caches:      %s\n' "$TMP_ROOT"
    printf '  NVIDIA:      %s\n' "$("$BIN_DIR/junest-nvidia" path 2>/dev/null || echo 'not used')"
    printf '  desktop:     %s\n' "$(config_get DESKTOP | grep . || echo 'none (GNOME)')"
    printf '  start with:  junest\n'
}

# Single step on the existing install.
if [[ -n $STEP ]]; then
    ROOTFS=$(config_get JUNEST_HOME)
    is_rootfs "$ROOTFS" || die "no JuNest install found, run ./install.sh first"
    make_tmp_root
    install_wrappers
    install_guest_helpers "$ROOTFS"
    configure_timezone "$ROOTFS"
    case "$STEP" in
        desktop) setup_desktop "$ROOTFS" "$DESKTOP_CHOICE" ;;
        *) die "unknown step: $STEP" ;;
    esac
    exit 0
fi

preflight
choose_rootfs
cleanup_old "$ROOTFS"
(($(free_gib "$ROOTFS") >= 4)) || die "less than 4 GiB free for $ROOTFS"

install_junest
install_wrappers
write_config "$ROOTFS"
setup_rootfs "$ROOTFS"

configure_pacman "$ROOTFS"
configure_makepkg "$ROOTFS"
remove_yay
install_base_packages "$ROOTFS"
install_guest_helpers "$ROOTFS"
configure_timezone "$ROOTFS"

if [[ -r /sys/module/nvidia/version ]]; then
    log "preparing NVIDIA $(cat /sys/module/nvidia/version) userspace libraries"
    "$BIN_DIR/junest-nvidia" fetch
fi

setup_desktop "$ROOTFS" "$DESKTOP_CHOICE"

trim_rootfs "$ROOTFS"
summary
