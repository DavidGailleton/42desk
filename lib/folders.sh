# Folders step: which host folders are bound (same path) inside JuNest.
# shellcheck shell=bash

ADD_FOLDER_TAG="+add"

# Known folders: path, then description.
known_folders() {
    printf '%s\t%s\n' \
        "/goinfre/$USER"  "per-computer storage (~/goinfre points here)" \
        "/sgoinfre/$USER" "shared storage (~/sgoinfre points here)" \
        "/media"          "USB keys (/media/$USER/...)"
}

# check_folder <path> <rootfs>: prints why the path can't be bound, or nothing.
check_folder() {
    local p=$1 rootfs=$2
    [[ $p == /* ]] || { echo "not an absolute path"; return 1; }
    [[ $p != *[[:space:]]* ]] || { echo "contains a space (JuNest splits bind arguments)"; return 1; }
    [[ /$p/ != */../* && /$p/ != */./* ]] || { echo "contains . or .."; return 1; }
    p=${p%/}
    [[ -n $p ]] || { echo "/ can't be bound"; return 1; }
    case $p in
        /usr|/usr/*|/etc|/etc/*|/bin|/sbin|/lib|/lib32|/lib64|/libx32|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/boot|/boot/*|/var|/var/*)
            echo "system folder: it would replace JuNest's own"; return 1 ;;
        /tmp|/tmp/*|"$HOME"|"$HOME"/*)
            echo "already visible in JuNest (/tmp and the home are always shared)"; return 1 ;;
    esac
    [[ $p == "$rootfs" || $p == "$rootfs"/* || $rootfs == "$p"/* ]] &&
        { echo "contains or is inside the JuNest rootfs"; return 1; }
    [[ -d $p ]] || { echo "no such folder"; return 1; }
    return 0
}

# choose_folders <rootfs>: prints the chosen folders, one per line.
choose_folders() {
    local rootfs=$1 path desc state why new out
    local -a current=() known=() extra=() items=()
    if ((ASSUME_YES)) && [[ -n ${FOLDERS_PRESET+x} ]]; then
        tr ' ' '\n' <<<"$FOLDERS_PRESET" | grep . || true
        return 0
    fi
    mapfile -t current < <(config_get_array BINDS)
    # Never chosen (or nothing chosen): goinfre and sgoinfre start checked.
    ((${#current[@]})) || current=("/goinfre/$USER" "/sgoinfre/$USER")
    mapfile -t known < <(known_folders | cut -f1)
    for path in "${current[@]}"; do
        [[ " ${known[*]} " == *" $path "* ]] || extra+=("$path")
    done

    while :; do
        items=()
        while IFS=$'\t' read -r path desc; do
            state=OFF
            [[ " ${current[*]} " == *" $path "* ]] && state=ON
            items+=("$path" "$desc" "$state")
        done < <(known_folders)
        for path in "${extra[@]}"; do
            state=OFF
            [[ " ${current[*]} " == *" $path "* ]] && state=ON
            items+=("$path" "custom folder" "$state")
        done
        items+=("$ADD_FOLDER_TAG" "Add another folder..." OFF)
        out=$(ask_checklist "Host folders" \
            "Host folders visible in JuNest, at the same path. /tmp and your home are always shared." \
            "${items[@]}") || return 1
        mapfile -t current <<<"$out"
        [[ " ${current[*]} " == *" $ADD_FOLDER_TAG "* ]] || break
        # Add folders, one inputbox at a time, until left empty.
        local -a kept=()
        for path in "${current[@]}"; do [[ $path == "$ADD_FOLDER_TAG" ]] || kept+=("$path"); done
        current=("${kept[@]}")
        while new=$(ask_input "Add a folder" "Absolute path of a host folder (empty to finish):" ""); do
            [[ -n $new ]] || break
            # ~/goinfre and other links: bind the real folder.
            new=${new/#\~/$HOME}
            new=$(realpath -e -- "$new" 2>/dev/null || echo "${new%/}")
            if why=$(check_folder "$new" "$rootfs"); then
                extra+=("$new")
                current+=("$new")
            else
                ask_yesno "Add a folder" "$new: $why."$'\n\n'"Try another path?" || break
            fi
        done
    done
    for path in "${current[@]}"; do [[ -n $path ]] && echo "$path"; done
}

# setup_folders <rootfs>
setup_folders() {
    local rootfs=$1 out path why
    local -a chosen=() ok=()
    out=$(choose_folders "$rootfs") || die "aborted"
    [[ -n $out ]] && mapfile -t chosen <<<"$out"
    for path in "${chosen[@]}"; do
        # /media and the like may be missing now: bwrap's --bind-try skips them.
        if why=$(check_folder "$path" "$rootfs") || [[ $why == "no such folder" ]]; then
            [[ " ${ok[*]} " == *" $path "* ]] || ok+=("$path")
        else
            warn "skipping $path: $why"
        fi
    done
    config_set_array BINDS "${ok[@]}"
    log "host folders in JuNest: ${ok[*]:-none} (from the next junest start)"
}
