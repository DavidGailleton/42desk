# Configures the guest: caches in /tmp/$USER, mirrors, keyring, base packages.
# shellcheck shell=bash

BASE_PACKAGES=(
    base-devel git
    # GL/Vulkan loaders and Mesa (Intel/AMD); the NVIDIA libs come from the host
    # driver version through junest-nvidia, not from Arch packages.
    mesa lib32-mesa libglvnd lib32-libglvnd
    vulkan-icd-loader lib32-vulkan-icd-loader vulkan-intel lib32-vulkan-intel
    egl-wayland egl-gbm egl-x11
    mesa-utils vulkan-tools
)

guest()      { "$BIN_DIR/junest" -- "$@"; }
guest_root() { "$BIN_DIR/junest" -f -- "$@"; }

configure_pacman() {
    local rootfs=$1 conf=$1/etc/pacman.conf
    log "configuring pacman (cache in $TMP_ROOT/pacman-cache)"
    sed -i -E \
        -e "s|^#?CacheDir.*|CacheDir    = $TMP_ROOT/pacman-cache/|" \
        -e "s|^#?ParallelDownloads.*|ParallelDownloads = 5|" \
        "$conf"
    grep -q '^CacheDir' "$conf" || sed -i "/^\[options\]/a CacheDir    = $TMP_ROOT/pacman-cache/" "$conf"
    grep -q '^ParallelDownloads' "$conf" || sed -i '/^\[options\]/a ParallelDownloads = 5' "$conf"
    # 32-bit libs (Steam, Wine, lib32 GL drivers) live in multilib.
    if ! grep -q '^\[multilib\]' "$conf"; then
        if grep -q '^#\[multilib\]' "$conf"; then
            sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' "$conf"
        else
            printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >>"$conf"
        fi
    fi
    # shellcheck disable=SC2016
    printf '%s\n' \
        'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' \
        'Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch' \
        'Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch' \
        >"$rootfs/etc/pacman.d/mirrorlist"
}

configure_makepkg() {
    local conf=$1/etc/makepkg.conf
    log "configuring makepkg (builds in $TMP_ROOT/makepkg)"
    sed -i -E \
        -e "s|^#?BUILDDIR=.*|BUILDDIR=$TMP_ROOT/makepkg/build|" \
        -e "s|^#?SRCDEST=.*|SRCDEST=$TMP_ROOT/makepkg/src|" \
        -e "s|^#?SRCPKGDEST=.*|SRCPKGDEST=$TMP_ROOT/makepkg/srcpkg|" \
        -e "s|^#?PKGDEST=.*|PKGDEST=$TMP_ROOT/makepkg/pkg|" \
        -e "s|^#?MAKEFLAGS=.*|MAKEFLAGS=\"-j$(nproc)\"|" \
        "$conf"
    install -d -m 700 "$TMP_ROOT"/makepkg/{build,src,srcpkg,pkg}
}

install_base_packages() {
    local rootfs=$1
    if [[ ! -s $rootfs/etc/pacman.d/gnupg/pubring.gpg ]]; then
        log "initializing the pacman keyring"
        guest_root pacman-key --init
        guest_root pacman-key --populate archlinux
    fi
    log "updating the system and installing base packages"
    guest_root pacman -Sy --needed --noconfirm archlinux-keyring
    guest_root pacman -Su --noconfirm
    guest_root pacman -S --needed --noconfirm "${BASE_PACKAGES[@]}"
}

# The JuNest image ships an old yay-git linked to a fixed libalpm soname; it
# breaks on the first pacman upgrade, and nothing here needs an AUR helper.
# Run before install_base_packages: -Rns also drops deps like git, which the
# base install then reinstalls as explicit.
remove_yay() {
    local pkgs
    pkgs=$(guest pacman -Qq yay yay-git yay-bin 2>/dev/null | sort -u || true)
    [[ -z $pkgs ]] && return 0
    log "removing the image's AUR helper (${pkgs//$'\n'/ })"
    # shellcheck disable=SC2086
    guest_root pacman -Rns --noconfirm $pkgs
}

# The image ships UTC: use the host's timezone (clocks, logs, ...).
configure_timezone() {
    local zone
    zone=$(readlink -f /etc/localtime)
    zone=${zone#*/zoneinfo/}
    [[ -n $zone && -e $1/usr/share/zoneinfo/$zone ]] || return 0
    ln -sfn "/usr/share/zoneinfo/$zone" "$1/etc/localtime"
}

install_guest_helpers() {
    local rootfs=$1
    install -d "$rootfs/usr/local/bin"
    install -m 755 "$REPO_DIR"/guest/* "$rootfs/usr/local/bin/"
}

# Nothing large should stay in the rootfs (it may live in the home quota).
trim_rootfs() {
    rm -rf "${1:?}"/var/cache/pacman/pkg/*
}
