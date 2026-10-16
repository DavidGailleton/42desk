# Removes any previous JuNest setup (ours or hand-made) before a fresh install.
# shellcheck shell=bash

# Top-level entries of a normal rootfs; anything else is user data to keep.
_ROOTFS_ENTRIES=" bin boot dev etc home lib lib64 mnt opt proc root run sbin srv sys tmp usr var goinfre sgoinfre "

# Moves non-rootfs files out of <rootfs> into a backup dir next to it.
_backup_strays() {
    local rootfs=$1 backup entry name moved=0
    backup="$(dirname "$rootfs")/junest-backup-$(date +%Y%m%d-%H%M%S)"
    for entry in "$rootfs"/* "$rootfs"/.[!.]*; do
        [[ -e $entry || -L $entry ]] || continue
        name=$(basename "$entry")
        [[ $_ROOTFS_ENTRIES == *" $name "* ]] && continue
        mkdir -p "$backup"
        mv "$entry" "$backup/"
        moved=1
    done
    ((moved)) && warn "moved unknown files from $rootfs to $backup"
    return 0
}

# Deletes a rootfs; Arch ships read-only dirs, so make them writable first.
_remove_rootfs() {
    chmod -R u+rwX "$1" 2>/dev/null || true
    rm -rf "$1"
}

# cleanup_old <new-rootfs>
cleanup_old() {
    local new_rootfs=$1 old_rootfs="" p
    local -a rootfs=() other=() strays=()

    # shellcheck source=/dev/null
    [[ -r $CONFIG_FILE ]] && old_rootfs=$(JUNEST_HOME=''; . "$CONFIG_FILE"; echo "$JUNEST_HOME")

    for p in "$old_rootfs" "$DEFAULT_ROOTFS" "$new_rootfs"; do
        [[ -n $p && -e $p ]] || continue
        [[ " ${rootfs[*]} " == *" $p "* ]] && continue
        if is_rootfs "$p"; then
            rootfs+=("$p")
        elif [[ $p == "$new_rootfs" && -n $(ls -A "$p") ]]; then
            die "$p is not empty and is not a JuNest rootfs, pick another path"
        fi
    done
    for p in "$JUNEST_SRC" "$BIN_DIR"/{junest,junest-nvidia,prime-run} \
        "$HOME/.local/share/junest-nvidia" "$GOINFRE"/{pacman-cache,junest-nvidia}; do
        [[ -e $p || -L $p ]] && other+=("$p")
    done

    if ((${#rootfs[@]} + ${#other[@]} == 0)); then
        log "no previous setup found"
        return 0
    fi

    if pgrep -u "$USER" -x bwrap >/dev/null; then
        die "a JuNest session is running, close it before reinstalling"
    fi

    for p in "${rootfs[@]}"; do
        for entry in "$p"/* "$p"/.[!.]*; do
            [[ -e $entry || -L $entry ]] || continue
            [[ $_ROOTFS_ENTRIES == *" $(basename "$entry") "* ]] || strays+=("$entry")
        done
    done

    local msg="This removes the previous JuNest setup:"$'\n\n'
    for p in "${rootfs[@]}"; do msg+="  $p ($(du -sh "$p" 2>/dev/null | cut -f1))"$'\n'; done
    for p in "${other[@]}"; do msg+="  $p"$'\n'; done
    if ((${#strays[@]})); then
        msg+=$'\n'"These files inside the rootfs are not part of it and will be"$'\n'
        msg+="moved to a junest-backup-<date> folder next to it:"$'\n'
        for p in "${strays[@]}"; do msg+="  $p"$'\n'; done
    fi
    msg+=$'\n'"Continue?"
    ((ASSUME_YES)) && printf '%s\n' "$msg" >&2
    ask_yesno "Remove previous setup" "$msg" || die "aborted"

    for p in "${rootfs[@]}"; do
        _backup_strays "$p"
        log "removing $p"
        _remove_rootfs "$p"
    done
    for p in "${other[@]}"; do
        log "removing $p"
        rm -rf "$p"
    done
}
