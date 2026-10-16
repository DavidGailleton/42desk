# Fetches JuNest, installs our wrappers and creates the rootfs.
# shellcheck shell=bash

# write_config <rootfs>: sets JUNEST_HOME, keeps every other key (BINDS, ...).
write_config() {
    config_set JUNEST_HOME "$1"
    # BINDS: host folders bound at the same path inside JuNest.
    grep -q '^BINDS=' "$CONFIG_FILE" || echo 'BINDS=()' >>"$CONFIG_FILE"
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
    install -m 755 "$REPO_DIR"/bin/* "$BIN_DIR/"
}

setup_rootfs() {
    local rootfs=$1
    log "creating the JuNest rootfs in $rootfs"
    mkdir -p "$(dirname "$rootfs")"
    # The image tarball goes to /tmp/$USER/junest-setup, not /tmp.
    JUNEST_HOME=$rootfs JUNEST_TEMPDIR=$TMP_ROOT/junest-setup "$JUNEST_SRC/bin/junest" setup
    rm -rf "${TMP_ROOT:?}/junest-setup/"*
}
