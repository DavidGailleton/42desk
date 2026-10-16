# Apps step: choose apps by category (apps/*.list), install/remove them,
# then pick the default app per role for the configured desktop.
# shellcheck shell=bash

APPS_DIR=$REPO_DIR/apps
MIMEAPPS_MARK="# Written by 42_custom_desktop (apps step): defaults for this desktop only."

# MIME types each role is the default for; terminal is handled with $TERMINAL.
declare -A ROLE_MIMES=(
    [browser]="x-scheme-handler/http x-scheme-handler/https text/html"
    [files]="inode/directory"
    [editor]="text/plain text/x-csrc text/x-chdr text/x-c++src text/x-c++hdr text/x-python text/x-shellscript text/markdown"
    [image]="image/png image/jpeg image/gif image/webp image/svg+xml"
    [video]="video/mp4 video/x-matroska video/webm audio/mpeg audio/flac audio/ogg"
    [pdf]="application/pdf"
)
ROLE_ORDER=(terminal browser editor files video image pdf)

# Catalog, filled by load_catalog.
declare -a CATS=() APP_IDS=()
declare -A CAT_NAME=() CAT_ROLE=() CAT_APPS=() APP_PKGS=() APP_DESC=() APP_CAT=()

_trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

pkg_installed() { compgen -G "$1/var/lib/pacman/local/$2-[0-9]*" >/dev/null; }

load_catalog() {
    local f cat line id pkgs desc
    ((${#CATS[@]})) && return 0
    for f in "$APPS_DIR"/*.list; do
        cat=$(basename "$f" .list)
        CATS+=("$cat")
        CAT_NAME[$cat]=$(sed -n 's/^# name: *//p' "$f")
        CAT_ROLE[$cat]=$(sed -n 's/^# role: *//p' "$f")
        while IFS= read -r line; do
            [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
            IFS='|' read -r id pkgs desc <<<"$line"
            id=$(_trim "$id") pkgs=$(_trim "$pkgs") desc=$(_trim "$desc")
            [[ -z ${APP_PKGS[$id]+x} ]] || die "duplicate app id in catalog: $id"
            APP_IDS+=("$id")
            APP_PKGS[$id]=$pkgs APP_DESC[$id]=$desc APP_CAT[$id]=$cat
            CAT_APPS[$cat]+="$id "
        done <"$f"
    done
}

# Installed size in MiB of every catalog package, from one pacman -Si call.
declare -A PKG_MIB=()
load_sizes() {
    local name size unit
    # shellcheck disable=SC2046
    while read -r name size unit; do
        case $unit in
            KiB) PKG_MIB[$name]=$(awk -v s="$size" 'BEGIN { printf "%.1f", s / 1024 }') ;;
            MiB) PKG_MIB[$name]=$size ;;
            GiB) PKG_MIB[$name]=$(awk -v s="$size" 'BEGIN { printf "%.1f", s * 1024 }') ;;
            *) PKG_MIB[$name]=0 ;;
        esac
    done < <(guest pacman -Si $(for id in "${APP_IDS[@]}"; do echo "${APP_PKGS[$id]}"; done) 2>/dev/null |
        awk -F' *: *' '/^Name/ { n = $2 } /^Installed Size/ { split($2, a, " "); print n, a[1], a[2] }')
}

# app_mib <id>: total size of the app's packages, rounded.
app_mib() {
    local p total=0
    for p in ${APP_PKGS[$1]}; do
        total=$(awk -v t="$total" -v s="${PKG_MIB[$p]:-0}" 'BEGIN { print t + s }')
    done
    printf '%.0f' "$total"
}

# install_mib <pkg>...: installed size of what pacman would add, dependencies included.
install_mib() {
    local -a pkgs
    mapfile -t pkgs < <(guest pacman -Sp --needed --print-format '%n' "$@" 2>/dev/null)
    ((${#pkgs[@]})) || { echo 0; return 0; }
    guest pacman -Si "${pkgs[@]}" 2>/dev/null | awk -F' *: *' '/^Installed Size/ {
        split($2, a, " "); m = a[2] == "GiB" ? 1024 : a[2] == "KiB" ? 1 / 1024 : a[2] == "B" ? 1 / 1048576 : 1
        t += a[1] * m } END { printf "%.0f", t }'
}

# app_desktop_file <id>: the app's main .desktop file name inside the rootfs.
app_desktop_file() {
    local id=$1 files f
    # shellcheck disable=SC2086
    files=$(guest pacman -Qlq ${APP_PKGS[$id]} 2>/dev/null |
        grep -E '^/usr/share/applications/[^/]+\.desktop$' | xargs -r -n1 basename)
    [[ -n $files ]] || return 1
    for f in $files; do
        [[ ${f,,} == *"${id,,}"* ]] && { echo "$f"; return 0; }
    done
    head -n1 <<<"$files"
}

# desktop_exec <rootfs> <file.desktop>: the command of its Exec= line.
desktop_exec() {
    sed -n 's/^Exec=\([^ ]*\).*/\1/p' "$1/usr/share/applications/$2" | head -n1 | xargs -r basename
}

# choose_apps: prints the selected ids, one per line.
choose_apps() {
    local current cat id i=0 state mib
    local -a items
    current=" $(config_get APPS) "
    if ((ASSUME_YES)) && [[ -n ${APPS_PRESET:-} ]]; then
        tr ' ' '\n' <<<"$APPS_PRESET" | grep .
        return 0
    fi
    for cat in "${CATS[@]}"; do
        i=$((i + 1))
        items=()
        for id in ${CAT_APPS[$cat]}; do
            state=OFF
            [[ $current == *" $id "* ]] && state=ON
            mib=$(app_mib "$id")
            items+=("$id" "${APP_DESC[$id]} (${mib} MiB)" "$state")
        done
        ask_checklist "Apps: ${CAT_NAME[$cat]} ($i/${#CATS[@]})" \
            "Space toggles, Enter confirms. Sizes leave out dependencies; the summary at the end shows the real total." \
            "${items[@]}" || return 1
    done
}

# set_default_apps <rootfs> <id>...: one default per role, among the selected apps.
set_default_apps() {
    local rootfs=$1 role id file current choice
    shift
    local -a candidates items
    for role in "${ROLE_ORDER[@]}"; do
        candidates=()
        for id in "$@"; do
            [[ ${CAT_ROLE[${APP_CAT[$id]}]} == "$role" ]] && candidates+=("$id")
        done
        if ((${#candidates[@]} == 0)); then
            config_set "DEFAULT_${role^^}" ""
            continue
        fi
        current=$(config_get "DEFAULT_${role^^}")
        items=()
        for id in "${candidates[@]}"; do
            file=$(app_desktop_file "$id") || { warn "$id has no .desktop file"; continue; }
            items+=("$file" "${APP_DESC[$id]} ($id)" "$([[ $file == "$current" ]] && echo ON || echo OFF)")
        done
        ((${#items[@]})) || continue
        if ((${#items[@]} == 3)); then
            choice=${items[0]}
        else
            choice=$(ask_radiolist "Default ${role}" \
                "Several ${role} apps are selected: which one opens by default in your desktop?" \
                "${items[@]}") || return 1
        fi
        config_set "DEFAULT_${role^^}" "$choice"
        case $role in
            terminal) config_set APP_TERMINAL "$(desktop_exec "$rootfs" "$choice")" ;;
            browser)  config_set APP_BROWSER "$(desktop_exec "$rootfs" "$choice")" ;;
        esac
    done
    # Roles with no app selected also drop their command.
    [[ -n $(config_get DEFAULT_TERMINAL) ]] || config_set APP_TERMINAL ""
    [[ -n $(config_get DEFAULT_BROWSER) ]] || config_set APP_BROWSER ""
}

# write_defaults: ~/.config/<desktop>-mimeapps.list from the DEFAULT_* keys.
# Per-desktop file, so GNOME (which shares the home) keeps its own defaults.
write_defaults() {
    local name f role file mime
    name=$(config_get DESKTOP_NAME)
    # Drop the files we wrote for other desktops.
    for f in "$HOME"/.config/*-mimeapps.list; do
        [[ -e $f && $(head -n1 "$f") == "$MIMEAPPS_MARK" ]] || continue
        [[ -n $name && $f == "$HOME/.config/${name,,}-mimeapps.list" ]] && continue
        rm -f "$f"
    done
    [[ -n $name ]] || return 0
    f=$HOME/.config/${name,,}-mimeapps.list
    {
        echo "$MIMEAPPS_MARK"
        echo "[Default Applications]"
        for role in "${!ROLE_MIMES[@]}"; do
            file=$(config_get "DEFAULT_${role^^}")
            [[ -n $file ]] || continue
            for mime in ${ROLE_MIMES[$role]}; do echo "$mime=$file"; done
        done
    } >"$f"
}

# kept_packages [--apps <app id>...]: every package something configured needs:
# base, desktop, rice, 42 apps, and the apps (those given after --apps, even
# none, or else those in the config).
# shellcheck disable=SC2206,SC2207  # package lists are space-separated words
kept_packages() {
    local id rice desktop
    local -a apps=() keep=("${BASE_PACKAGES[@]}" "${DESKTOP_COMMON[@]}")
    load_catalog
    if [[ ${1:-} == --apps ]]; then
        shift
        apps=("$@")
    else
        read -ra apps <<<"$(config_get APPS)"
    fi
    for id in "${apps[@]}"; do keep+=(${APP_PKGS[$id]:-}); done
    desktop=$(config_get DESKTOP)
    [[ -n $desktop && -f $DESKTOP_DIR/$desktop.conf ]] && keep+=($(desktop_field "$desktop" PACKAGES))
    rice=$(config_get RICE)
    [[ -n $rice && -d $RICE_DIR/$rice ]] && keep+=($(rice_packages "$rice"))
    keep+=($(ft_apps_packages))
    echo "${keep[*]}"
}

# setup_apps <rootfs>
setup_apps() {
    local rootfs=$1 id p total=0 free msg out
    local -a selected=() install=() deselected=() remove=()
    load_catalog
    load_sizes
    out=$(choose_apps) || die "aborted"
    [[ -n $out ]] && mapfile -t selected <<<"$out"

    for id in "${selected[@]}"; do
        [[ -n ${APP_PKGS[$id]+x} ]] || die "unknown app: $id"
        for p in ${APP_PKGS[$id]}; do install+=("$p"); done
    done
    ((${#install[@]})) && total=$(install_mib "${install[@]}")
    for id in $(config_get APPS); do
        [[ " ${selected[*]} " == *" $id "* || -z ${APP_PKGS[$id]+x} ]] && continue
        deselected+=("$id")
        for p in ${APP_PKGS[$id]}; do remove+=("$p"); done
    done

    free=$(free_gib "$rootfs")
    total=$(printf '%.0f' "$total")
    msg="Apps: ${selected[*]:-none}"$'\n'"New on disk, with dependencies: ${total} MiB (free: ${free} GiB)"
    ((${#remove[@]})) && msg+=$'\n\n'"Remove: ${deselected[*]}"
    ((total / 1024 < free)) || die "not enough space: ${total} MiB needed, ${free} GiB free"
    ask_yesno "Apps" "$msg"$'\n\n'"Continue?" || die "aborted"

    # Packages still needed by something else stay: base, desktop, rice, other apps.
    ((${#remove[@]})) && remove_orphans "$(kept_packages --apps "${selected[@]}")" "${remove[@]}"
    if ((${#install[@]})); then
        log "installing: ${selected[*]}"
        guest_root pacman -S --needed --noconfirm "${install[@]}"
        # Chosen apps must never be removed as someone's orphaned dependency.
        guest_root pacman -D --asexplicit "${install[@]}" >/dev/null
    fi
    config_set APPS "${selected[*]}"
    trim_rootfs "$rootfs"

    if [[ -n $(config_get DESKTOP) ]]; then
        set_default_apps "$rootfs" "${selected[@]}" || die "aborted"
        write_defaults
    fi
    # Terminal colors for newly installed terminals.
    rice_refresh "$rootfs"
    log "apps done"
}
