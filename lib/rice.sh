# Rice step: our own looks for the configured desktop. A rice is a palette and
# a few layout values (rices/<id>/rice.conf) rendered into shared templates
# (rices/_templates, listed in its `files` manifest). Official packages only.
# Works from the host and from inside the JuNest session (rofi picker).
# shellcheck shell=bash

RICE_DIR=$REPO_DIR/rices
TEMPLATE_DIR=$RICE_DIR/_templates
RICE_STATE=$CONFIG_DIR/rice          # rice.env, Xresources, wallpaper, files
RICE_BACKUP=$CONFIG_DIR/rice-backup  # the user's files a rice replaced
RICE_MARK="Written by 42desk (rice step): replaced on rice changes, removed by the stock look."
# Set when a rice is rendered for XFCE: its xfconf settings (theme, fonts,
# wallpaper) then get reset by the next stock XFCE session (42desk-rice-apply).
XFCE_RESET_FLAG=$CONFIG_DIR/rice-xfce-reset

# Same for every rice; a rice's PACKAGES add its font.
RICE_PACKAGES=(picom polybar rofi dunst feh xsettingsd xorg-xrdb libnotify
    materia-gtk-theme papirus-icon-theme ttf-nerd-fonts-symbols-mono)

# rice_field <id> <VAR>: prints a variable (arrays joined by spaces) from rice.conf.
rice_field() {
    # shellcheck source=/dev/null
    (. "$RICE_DIR/$1/rice.conf" && eval "printf '%s' \"\${$2[*]}\"")
}

# rice_ids [<desktop>]: rice ids, only those supporting <desktop> if given.
rice_ids() {
    local f id
    for f in "$RICE_DIR"/*/rice.conf; do
        id=$(basename "$(dirname "$f")")
        [[ -z ${1:-} || " $(rice_field "$id" DESKTOPS) " == *" $1 "* ]] && echo "$id"
    done
}

# rice_vars <id> <desktop>: KEY<TAB>VALUE for every template token.
rice_vars() {
    local id=$1 desktop=$2
    (
        # shellcheck source=/dev/null
        . "$RICE_DIR/$id/rice.conf"
        local i k
        for k in NAME FONT FONT_SIZE FONT_SIZE_SMALL GTK_THEME ICONS GAP BORDER RADIUS \
            BG BG_ALT FG FG_DIM ACCENT ACCENT2 URGENT; do
            printf '%s\t%s\n' "$k" "${!k}"
        done
        for i in "${!COLORS[@]}"; do printf 'C%s\t%s\n' "$i" "${COLORS[i]}"; done
        printf '%s\t%s\n' \
            MARK "$RICE_MARK" \
            RICE "$id" \
            HOME "$HOME" \
            USER "$USER" \
            WALLPAPER "$RICE_STATE/wallpaper.jpg" \
            GAP_HALF "$((GAP / 2))" \
            WM_MODULE "$desktop" \
            BAR_BOTTOM "$([[ $BAR_POSITION == bottom ]] && echo true || echo false)"
    )
}

# render_template <template> <vars-file> <out>: replaces {{KEY}} tokens; any
# token left (a typo, a missing palette entry) is an error.
render_template() {
    local tpl=$1 vars=$2 out=$3 script left
    script=$(awk -F'\t' '{
        v = $2; gsub(/[\\|&]/, "\\\\&", v)
        printf "s|{{%s}}|%s|g\n", $1, v }' "$vars")
    sed -e "$script" "$tpl" >"$out"
    left=$(grep -o '{{[A-Za-z0-9_]*}}' "$out" | sort -u | paste -sd' ' || true)
    [[ -z $left ]] || die "$tpl: unknown tokens: $left"
    head -n3 "$out" | grep -qF "$RICE_MARK" || die "$tpl: the {{MARK}} line must be in the first 3 lines"
}

# is_ours <file>: carries the rice marker.
is_ours() { [[ -f $1 ]] && head -n3 "$1" | grep -qF "$RICE_MARK"; }

# _place <rendered> <dest> <mode>: a user's own file is moved to the backup
# first (an older backup of the same path is kept, the newer one dated).
# Folders it creates are listed in $RICE_STATE/dirs, to go with the stock look.
_place() {
    local src=$1 dest=$2 mode=$3 rel bak d top=""
    d=$(dirname "$dest")
    while [[ ! -d $d && $d == "$HOME"/* ]]; do top=$d; d=$(dirname "$d"); done
    [[ -n $top ]] && echo "$top" >>"$RICE_STATE/dirs"
    rel=${dest#"$HOME"/}
    bak=$RICE_BACKUP/$rel
    if [[ -e $dest || -L $dest ]] && ! is_ours "$dest"; then
        [[ -e $bak || -L $bak ]] && bak+=.$(date +%Y%m%d-%H%M%S)
        mkdir -p "$(dirname "$bak")"
        mv "$dest" "$bak"
        log "backed up ~/$rel"
    fi
    install -D -m "$mode" "$src" "$dest"
}

# _unplace <dest>: removes our file and brings the user's back.
_unplace() {
    local dest=$1 rel bak
    rel=${dest#"$HOME"/}
    bak=$RICE_BACKUP/$rel
    is_ours "$dest" && rm -f "$dest"
    if [[ ! -e $dest && ( -e $bak || -L $bak ) ]]; then
        mv "$bak" "$dest"
        log "restored ~/$rel"
    fi
    rmdir -p "$(dirname "$bak")" 2>/dev/null || true
}

# awesome has no template: its own rc.lua, using our theme, tiling by default
# (the stock first layout floats, which hides the rice's gaps), plus the 42 keys.
_render_awesome_rc() {
    local rootfs=$1 out=$2 src=$1/etc/xdg/awesome/rc.lua
    [[ -r $src ]] || die "awesome is not installed in $rootfs"
    {
        echo "-- $RICE_MARK"
        sed -e 's|^beautiful.init(.*)$|beautiful.init(gears.filesystem.get_configuration_dir() .. "theme.lua")|' \
            -e 's/^terminal = "xterm"/terminal = "x-terminal-emulator"/' \
            -e 's/^\(    awful.tag(.*, s, \)awful.layout.layouts\[1\])$/\1awful.layout.suit.tile)/' \
            "${AWESOME_KEYS_SED[@]}" "$src"
        cat <<'LUA'

-- 42desk: lock (through the host), back to GNOME (also Mod4+Shift+q), log out,
-- app search (Mod4+space, Mod4+d), next keyboard layout, rice picker
root.keys(gears.table.join(root.keys(),
    awful.key({ "Control", "Mod1" }, "l", function() awful.spawn("ft_lock") end,
        { description = "lock screen", group = "42" }),
    awful.key({ modkey }, "b", function() awesome.quit() end,
        { description = "back to GNOME", group = "42" }),
    awful.key({ modkey, "Control", "Shift" }, "q",
        function() awful.spawn.easy_async("42desk-logout", function() awesome.quit() end) end,
        { description = "log out", group = "42" }),
    awful.key({ modkey }, "d", function() awful.spawn("rofi -show drun") end,
        { description = "app launcher", group = "42" }),
    awful.key({ modkey }, "space", function() awful.spawn("rofi -show drun") end,
        { description = "app search", group = "42" }),
    awful.key({ modkey, "Shift" }, "space", function() awful.spawn("42desk-kbd-next") end,
        { description = "next keyboard layout", group = "42" }),
    awful.key({ modkey, "Shift" }, "t", function() awful.spawn("42desk-rice-pick") end,
        { description = "change the rice", group = "42" })))
LUA
    } >"$out"
    grep -q 'get_configuration_dir() .. "theme.lua"' "$out" ||
        die "awesome's rc.lua changed: beautiful.init() was not found"
    grep -qF "$AWESOME_KEYS_CHECK" "$out" ||
        die "awesome's rc.lua changed: its Super+Space layout key was not found"
}

# rice_render <rootfs> <id> <desktop>: renders every file of the manifest for
# this desktop (and the installed terminals), removes the ones no longer used.
rice_render() {
    local rootfs=$1 id=$2 desktop=$3 work vars dtops app tpl dest mode apps f
    local -a old=() new=()
    work=$(mktemp -d "$TMP_ROOT/rice.XXXXXX")
    vars=$work/vars
    rice_vars "$id" "$desktop" >"$vars"
    apps=" $(config_get APPS) "
    install -d "$RICE_STATE"
    [[ -r $RICE_STATE/files ]] && mapfile -t old <"$RICE_STATE/files"

    while IFS='|' read -r dtops app tpl dest mode; do
        dtops=$(_trim "$dtops") app=$(_trim "$app") tpl=$(_trim "$tpl") dest=$(_trim "$dest") mode=$(_trim "$mode")
        [[ $dtops == '*' || " $dtops " == *" $desktop "* ]] || continue
        [[ $app == - || $apps == *" $app "* ]] || continue
        render_template "$TEMPLATE_DIR/$tpl" "$vars" "$work/out"
        _place "$work/out" "$HOME/$dest" "${mode:-644}"
        new+=("$HOME/$dest")
    done < <(grep -Ev '^[[:space:]]*(#|$)' "$TEMPLATE_DIR/files")
    if [[ $desktop == awesome ]]; then
        _render_awesome_rc "$rootfs" "$work/out"
        _place "$work/out" "$HOME/.config/awesome/rc.lua" 644
        new+=("$HOME/.config/awesome/rc.lua")
    fi

    for f in "${old[@]}"; do
        [[ " ${new[*]} " == *" $f "* ]] || _unplace "$f"
    done
    printf '%s\n' "${new[@]}" >"$RICE_STATE/files"
    install -m 644 "$RICE_DIR/$id/wallpaper.jpg" "$RICE_STATE/wallpaper.jpg"
    [[ $desktop == xfce ]] && touch "$XFCE_RESET_FLAG"
    # Read by the guest's 42desk-start and 42desk-rice-apply.
    {
        echo "# $RICE_MARK"
        awk -F'\t' '$1 ~ /^(RICE|NAME|FONT|FONT_SIZE|FONT_SIZE_SMALL|GTK_THEME|ICONS|WALLPAPER)$/' "$vars" |
            while IFS=$'\t' read -r k v; do printf 'RICE_%s=%q\n' "$k" "$v"; done
        printf 'RICE_DESKTOP=%q\n' "$desktop"
    } >"$RICE_STATE/rice.env"
    rm -rf "$work"
}

# rice_remove_files: back to the stock look (the user's files come back).
rice_remove_files() {
    local f
    [[ -r $RICE_STATE/files ]] || return 0
    while IFS= read -r f; do _unplace "$f"; done <"$RICE_STATE/files"
    # Folders the rice created, if nothing else was put in them.
    if [[ -r $RICE_STATE/dirs ]]; then
        while IFS= read -r f; do
            [[ -d $f ]] && find "$f" -depth -type d -empty -delete
        done < <(sort -u "$RICE_STATE/dirs")
    fi
    rm -rf "$RICE_STATE"
    if [[ -d $RICE_BACKUP ]] && ! rmdir "$RICE_BACKUP" 2>/dev/null; then
        warn "older versions of your files are kept in $RICE_BACKUP"
    fi
}

# rice_packages <id>: what the rice needs installed.
rice_packages() {
    echo "${RICE_PACKAGES[*]} $(rice_field "$1" PACKAGES)"
}

# rice_reload: applies the files to a running session: directly inside it, or
# through junest from the host with the session's DISPLAY and bus.
rice_reload() {
    local env=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/42-junest/session.env
    if [[ -n ${JUNEST_ENV:-} && -n ${DISPLAY:-} ]] && command -v 42desk-rice-apply >/dev/null; then
        42desk-rice-apply reload || warn "the running desktop could not be reloaded"
    elif [[ -r $env ]]; then
        # shellcheck disable=SC2046  # KEY=value words from 42desk-start
        guest env $(cat "$env") 42desk-rice-apply reload || warn "the running desktop could not be reloaded"
    else
        log "the look applies at the next login"
    fi
}

# choose_rice <desktop>: prints a rice id, or "stock".
choose_rice() {
    local desktop=$1 current id
    local -a items=(stock "Stock: the desktop's default look")
    current=$(config_get RICE)
    if [[ -n ${RICE_CHOICE:-} ]]; then
        [[ $RICE_CHOICE == stock ]] || [[ " $(rice_ids "$desktop" | paste -sd' ') " == *" $RICE_CHOICE "* ]] ||
            die "unknown rice for $desktop: $RICE_CHOICE (one of: stock $(rice_ids "$desktop" | paste -sd' '))"
        echo "$RICE_CHOICE"
        return 0
    fi
    if ((ASSUME_YES)); then echo "${current:-stock}"; return 0; fi
    for id in $(rice_ids "$desktop"); do
        items+=("$id" "$(rice_field "$id" NAME): $(rice_field "$id" DESC)")
    done
    ask_menu "Look" \
        "A rice themes the window manager, bar, launcher, notifications, GTK apps and terminals. Your own config files are backed up and come back with Stock. Super+Shift+T switches rices in the desktop." \
        "${current:-stock}" "${items[@]}"
}

# _drop_rice <rootfs>: stock look; the rice packages (and every rice's font)
# go if nothing else needs them.
_drop_rice() {
    local rootfs=$1 id
    local -a pkgs=("${RICE_PACKAGES[@]}") font
    [[ -n $(config_get RICE) ]] || return 0
    log "back to the stock look"
    rice_remove_files
    config_set RICE ""
    for id in $(rice_ids); do
        read -ra font <<<"$(rice_field "$id" PACKAGES)"
        pkgs+=("${font[@]}")
    done
    remove_orphans "$(kept_packages)" "${pkgs[@]}"
}

# setup_rice <rootfs>
setup_rice() {
    local rootfs=$1 desktop choice
    local -a pkgs
    desktop=$(config_get DESKTOP)
    if [[ -z $desktop ]]; then
        _drop_rice "$rootfs"
        log "no desktop configured: no rice"
        return 0
    fi
    choice=$(choose_rice "$desktop") || die "aborted"
    if [[ $choice == stock ]]; then
        _drop_rice "$rootfs"
        rice_reload
        return 0
    fi

    read -ra pkgs <<<"$(rice_packages "$choice")"
    log "installing the $(rice_field "$choice" NAME) rice"
    guest_root pacman -S --needed --noconfirm "${pkgs[@]}"
    rice_render "$rootfs" "$choice" "$desktop"
    config_set RICE "$choice"
    # The previous rice's font stays: switching back works offline, from the
    # rofi picker too. Fonts go with the stock look.
    trim_rootfs "$rootfs"
    rice_reload
    log "rice: $(rice_field "$choice" NAME)"
}

# rice_refresh <rootfs>: after a desktop or apps change, re-render the rice
# (other WM files, new terminals), or drop it if the desktop has none.
rice_refresh() {
    local rootfs=$1 rice desktop
    rice=$(config_get RICE)
    desktop=$(config_get DESKTOP)
    [[ -n $rice ]] || return 0
    if [[ -n $desktop && -d $RICE_DIR/$rice && " $(rice_field "$rice" DESKTOPS) " == *" $desktop "* ]]; then
        rice_render "$rootfs" "$rice" "$desktop"
    else
        _drop_rice "$rootfs"
    fi
}
