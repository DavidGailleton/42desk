# Fetches JuNest, installs our wrappers and creates the rootfs.
# shellcheck shell=bash

# write_config <rootfs>: keeps BINDS from an existing config.
write_config() {
    local rootfs=$1 binds=""
    # shellcheck source=/dev/null
    [[ -r $CONFIG_FILE ]] &&
        binds=$(BINDS=(); . "$CONFIG_FILE"; ((${#BINDS[@]})) && printf '%q ' "${BINDS[@]}")
    binds="(${binds% })"
    mkdir -p "$CONFIG_DIR"
    cat >"$CONFIG_FILE" <<EOF
# Written by 42_custom_desktop/install.sh, read by ~/.local/bin/junest.
JUNEST_HOME=$(printf '%q' "$rootfs")
# Host folders bound at the same path inside JuNest.
BINDS=$binds
EOF
}

install_junest() {
    log "cloning JuNest $JUNEST_VERSION"
    mkdir -p "$(dirname "$JUNEST_SRC")"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$JUNEST_VERSION" \
        "$JUNEST_REPO" "$JUNEST_SRC"
}

install_wrappers() {
    log "installing wrappers to $BIN_DIR"
    mkdir -p "$BIN_DIR"
    install -m 755 "$REPO_DIR/bin/junest" "$REPO_DIR/bin/junest-nvidia" "$BIN_DIR/"
}

setup_rootfs() {
    local rootfs=$1
    log "creating the JuNest rootfs in $rootfs"
    mkdir -p "$(dirname "$rootfs")"
    # The image tarball goes to /tmp/$USER/junest-setup, not /tmp.
    JUNEST_HOME=$rootfs JUNEST_TEMPDIR=$TMP_ROOT/junest-setup "$JUNEST_SRC/bin/junest" setup
    rm -rf "${TMP_ROOT:?}/junest-setup/"*
}
