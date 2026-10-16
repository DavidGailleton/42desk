# Fetches JuNest, installs our wrappers and creates the rootfs.
# shellcheck shell=bash

# write_config <rootfs>: sets JUNEST_HOME, keeps every other key. BINDS is
# left to the folders step: no BINDS key means "never asked" (defaults apply).
write_config() {
    config_set JUNEST_HOME "$1"
}

install_junest() {
    log "cloning JuNest $JUNEST_VERSION"
    mkdir -p "$(dirname "$JUNEST_SRC")"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$JUNEST_VERSION" \
        "$JUNEST_REPO" "$JUNEST_SRC"
}

install_wrappers() {
    local f
    log "installing wrappers to $BIN_DIR"
    mkdir -p "$BIN_DIR"
    for f in "$REPO_DIR"/bin/*; do
        [[ $(basename "$f") == 42desk ]] || install -m 755 "$f" "$BIN_DIR/"
    done
    # 42desk needs its lib/ and catalogs: a launcher into this repo.
    printf '#!/bin/sh\n# 42desk launcher, written by install_wrappers.\nexec %q "$@"\n' \
        "$REPO_DIR/bin/42desk" >"$BIN_DIR/42desk"
    chmod 755 "$BIN_DIR/42desk"
}

setup_rootfs() {
    local rootfs=$1
    log "creating the JuNest rootfs in $rootfs"
    mkdir -p "$(dirname "$rootfs")"
    # The image tarball goes to /tmp/$USER/junest-setup, not /tmp.
    JUNEST_HOME=$rootfs JUNEST_TEMPDIR=$TMP_ROOT/junest-setup "$JUNEST_SRC/bin/junest" setup
    rm -rf "${TMP_ROOT:?}/junest-setup/"*
}
