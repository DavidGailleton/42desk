# Desktop environment step: choice, packages, stock config, and the ways in:
# GNOME autostart (login), app-grid launcher and Super+B (from GNOME).
# shellcheck shell=bash

DESKTOP_DIR=$REPO_DIR/desktops
SHARE_DIR=$HOME/.local/share/42-junest
AUTOSTART_FILE=$HOME/.config/autostart/42desk.desktop
LAUNCHER_FILE=$HOME/.local/share/applications/42desk-session.desktop
ENTRY_MARK="X-42desk-Generated=true"
SHORTCUT_SCHEMA=org.gnome.settings-daemon.plugins.media-keys
SHORTCUT_PATH=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/42desk/
SHORTCUT_KEY="<Super>b"
# The old login hook: the 42 display manager never runs Xsession, so it never
# worked. Only kept to remove it.
XSESSIONRC=$HOME/.xsessionrc
HOOK_BEGIN="# >>> 42-junest >>>"
HOOK_END="# <<< 42-junest <<<"

# Shared by every desktop: fallback terminal and launcher, fonts, X tools,
# pgrep/pkill (bspwmrc, rice reloads) and whiptail (42desk in a desktop terminal).
DESKTOP_COMMON=(xterm dmenu ttf-dejavu xorg-setxkbmap xorg-xrandr xorg-xsetroot xdg-utils
    procps-ng libnewt)

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
        "Takes over from GNOME right after login. Quitting it goes back to GNOME; Super+B in GNOME comes back." \
        "${current:-none}" "${items[@]}"
}

# _remove_login_hook: drops the old marked block from ~/.xsessionrc.
_remove_login_hook() {
    local tmp
    rm -f "$SHARE_DIR/xsessionrc"
    rmdir "$SHARE_DIR" 2>/dev/null || true
    [[ -e $XSESSIONRC ]] && grep -qxF "$HOOK_BEGIN" "$XSESSIONRC" || return 0
    tmp=$(mktemp "$XSESSIONRC.XXXXXX")
    awk -v b="$HOOK_BEGIN" -v e="$HOOK_END" '
        $0 == b { skip = 1; next }  $0 == e { skip = 0; next }  !skip' "$XSESSIONRC" >"$tmp"
    if [[ -s $tmp ]]; then mv "$tmp" "$XSESSIONRC"; else rm -f "$tmp" "$XSESSIONRC"; fi
}

# _entry <name> <args>: a .desktop entry that runs junest-session.
_entry() {
    printf '%s\n' "[Desktop Entry]" "Type=Application" "Name=$1" \
        "Comment=Switch from GNOME to the 42desk desktop (quitting it comes back)" \
        "Exec=$BIN_DIR/junest-session${2:+ $2}" "Icon=preferences-desktop" "Terminal=false" \
        "OnlyShowIn=GNOME;" "$ENTRY_MARK"
}

# _ours <file>: the file exists and 42desk wrote it.
_ours() { [[ -r $1 ]] && grep -qxF "$ENTRY_MARK" "$1"; }

# _shortcut_list: GNOME's custom shortcut paths, one per line.
_shortcut_list() {
    gsettings get "$SHORTCUT_SCHEMA" custom-keybindings 2>/dev/null | grep -o "'[^']*'" | tr -d "'"
}

shortcut_present() { _shortcut_list | grep -qxF "$SHORTCUT_PATH"; }

# _set_shortcut 0|1: adds or removes our own entry in GNOME's custom
# shortcuts (never a customN one, which belongs to the user).
_set_shortcut() {
    local enable=$1 p list=""
    command -v gsettings >/dev/null || return 0
    while IFS= read -r p; do
        [[ -n $p && $p != "$SHORTCUT_PATH" ]] && list+="${list:+, }'$p'"
    done < <(_shortcut_list)
    if ((enable)); then
        list+="${list:+, }'$SHORTCUT_PATH'"
        local kb="$SHORTCUT_SCHEMA.custom-keybinding:$SHORTCUT_PATH"
        if ! { gsettings set "$kb" name "Switch to $(config_get DESKTOP_NAME)" &&
            gsettings set "$kb" command "$BIN_DIR/junest-session" &&
            gsettings set "$kb" binding "$SHORTCUT_KEY"; }; then
            warn "could not add the $SHORTCUT_KEY shortcut to GNOME (no session bus?)"
            return 0
        fi
    else
        dconf reset -f "$SHORTCUT_PATH" 2>/dev/null
    fi
    gsettings set "$SHORTCUT_SCHEMA" custom-keybindings "[$list]" 2>/dev/null ||
        warn "could not update GNOME's custom shortcuts (no session bus?)"
}

# set_session_entries 0|1: the ways into the desktop. On: the GNOME autostart
# entry (takes over at login), the app-grid launcher and Super+B. Off: removes
# ours. Either way, the old ~/.xsessionrc hook goes.
set_session_entries() {
    local enable=$1 name f
    _remove_login_hook
    if ((enable)); then
        name="Switch to $(config_get DESKTOP_NAME)"
        install -d "$(dirname "$AUTOSTART_FILE")" "$(dirname "$LAUNCHER_FILE")"
        { _entry "42desk ($name)" --login
          printf '%s\n' "X-GNOME-Autostart-enabled=true" "X-GNOME-AutoRestart=false" \
              "X-GNOME-Autostart-Phase=Application" "NoDisplay=true"; } >"$AUTOSTART_FILE"
        _entry "$name" >"$LAUNCHER_FILE"
    else
        for f in "$AUTOSTART_FILE" "$LAUNCHER_FILE"; do _ours "$f" && rm -f "$f"; done
    fi
    _set_shortcut "$enable"
}

# session_entries_ok: autostart, launcher and shortcut are in place and current.
session_entries_ok() {
    _ours "$AUTOSTART_FILE" && _ours "$LAUNCHER_FILE" &&
        grep -qxF "Exec=$BIN_DIR/junest-session --login" "$AUTOSTART_FILE" &&
        grep -qxF "Name=Switch to $(config_get DESKTOP_NAME)" "$LAUNCHER_FILE" &&
        { ! command -v gsettings >/dev/null || shortcut_present; }
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
        set_session_entries 0
        config_set DESKTOP ""
        config_set DESKTOP_START ""
        config_set DESKTOP_NAME ""
        write_defaults
        rice_refresh "$rootfs"
        return 0
    fi

    log "installing $(desktop_field "$choice" NAME)"
    guest_root pacman -S --needed --noconfirm "${DESKTOP_COMMON[@]}" "${new[@]}"
    # shellcheck source=/dev/null
    (. "$DESKTOP_DIR/$choice.conf" && stock_config "$rootfs")

    config_set DESKTOP "$choice"
    config_set DESKTOP_START "$(desktop_field "$choice" START)"
    config_set DESKTOP_NAME "$(desktop_field "$choice" NAME)"
    set_session_entries 1
    # Default apps (apps step) follow the desktop's name; the rice its files.
    write_defaults
    rice_refresh "$rootfs"
    trim_rootfs "$rootfs"
    log "$(desktop_field "$choice" NAME) takes over from GNOME at the next login, or now with $SHORTCUT_KEY (Ctrl+Alt+L locks; quitting it goes back to GNOME)"
}
