# Desktop environment step: choice, packages, stock config, login hook.
# shellcheck shell=bash

DESKTOP_DIR=$REPO_DIR/desktops
SHARE_DIR=$HOME/.local/share/42-junest
XSESSIONRC=$HOME/.xsessionrc
HOOK_BEGIN="# >>> 42-junest >>>"
HOOK_END="# <<< 42-junest <<<"

# Shared by every desktop: fallback terminal and launcher, fonts, X tools.
DESKTOP_COMMON=(xterm dmenu ttf-dejavu xorg-setxkbmap xorg-xrandr xorg-xsetroot xdg-utils)

# desktop_field <id> <VAR>: prints a variable from desktops/<id>.conf.
desktop_field() {
    # shellcheck source=/dev/null
    (. "$DESKTOP_DIR/$1.conf" && eval "printf '%s' \"\${$2[*]}\"")
}

desktop_ids() {
    local f
    for f in "$DESKTOP_DIR"/*.conf; do basename "$f" .conf; done
}

# choose_desktop [<id>|none]: prints the chosen id, or "none".
choose_desktop() {
    local preset=${1:-} current id
    local -a items=(none "None, keep GNOME only")
    current=$(config_get DESKTOP)
    for id in $(desktop_ids); do
        items+=("$id" "$(desktop_field "$id" NAME): $(desktop_field "$id" DESC)")
    done
    if [[ -n $preset ]]; then
        [[ $preset == none || -f $DESKTOP_DIR/$preset.conf ]] || die "unknown desktop: $preset"
        echo "$preset"
        return 0
    fi
    # Without a question to ask, keep what is configured (none on a first install).
    if ((ASSUME_YES)); then echo "${current:-none}"; return 0; fi
    ask_menu "Desktop environment" \
        "Starts after the GDM login, before GNOME. Quitting it logs out; if it fails, GNOME starts instead." \
        "${current:-none}" "${items[@]}"
}

# Writes or removes the marked block in ~/.xsessionrc.
_set_login_hook() {
    local enable=$1 tmp
    tmp=$(mktemp "$XSESSIONRC.XXXXXX")
    [[ -e $XSESSIONRC ]] && awk -v b="$HOOK_BEGIN" -v e="$HOOK_END" '
        $0 == b { skip = 1; next }  $0 == e { skip = 0; next }  !skip' "$XSESSIONRC" >"$tmp"
    if ((enable)); then
        printf '%s\n%s\n%s\n' "$HOOK_BEGIN" \
            "if [ -r \"\$HOME/.local/share/42-junest/xsessionrc\" ]; then . \"\$HOME/.local/share/42-junest/xsessionrc\"; fi" \
            "$HOOK_END" >>"$tmp"
    fi
    if [[ -s $tmp ]]; then mv "$tmp" "$XSESSIONRC"; else rm -f "$tmp" "$XSESSIONRC"; fi
}

# setup_desktop <rootfs> [<id>|none]
setup_desktop() {
    local rootfs=$1 choice current p
    local -a old=() new=() remove=()
    choice=$(choose_desktop "${2:-}") || die "aborted"
    current=$(config_get DESKTOP)

    [[ $choice != none ]] && read -ra new <<<"$(desktop_field "$choice" PACKAGES)"
    # Drop the previous desktop's packages, except those the new one also uses.
    if [[ -n $current && $current != "$choice" && -f $DESKTOP_DIR/$current.conf ]]; then
        read -ra old <<<"$(desktop_field "$current" PACKAGES)"
        for p in "${old[@]}"; do
            [[ " ${new[*]} " == *" $p "* ]] && continue
            [[ -d $rootfs/var/lib/pacman/local && -n $(compgen -G "$rootfs/var/lib/pacman/local/$p-[0-9]*") ]] &&
                remove+=("$p")
        done
        if ((${#remove[@]})); then
            log "removing $current: ${remove[*]}"
            guest_root pacman -Rns --noconfirm "${remove[@]}"
        fi
    fi

    if [[ $choice == none ]]; then
        log "no desktop: GNOME starts as usual"
        _set_login_hook 0
        config_set DESKTOP ""
        config_set DESKTOP_START ""
        config_set DESKTOP_NAME ""
        return 0
    fi

    log "installing $(desktop_field "$choice" NAME)"
    guest_root pacman -S --needed --noconfirm "${DESKTOP_COMMON[@]}" "${new[@]}"
    # shellcheck source=/dev/null
    (. "$DESKTOP_DIR/$choice.conf" && stock_config "$rootfs")

    install -d "$SHARE_DIR"
    install -m 644 "$REPO_DIR/share/xsessionrc" "$SHARE_DIR/xsessionrc"
    _set_login_hook 1
    config_set DESKTOP "$choice"
    config_set DESKTOP_START "$(desktop_field "$choice" START)"
    config_set DESKTOP_NAME "$(desktop_field "$choice" NAME)"
    trim_rootfs "$rootfs"
    log "$(desktop_field "$choice" NAME) starts at the next login (Ctrl+Alt+L locks)"
}
