# 42 apps step: 42 tools rebuilt inside JuNest (the host's can't run there:
# norminette uses the host's Python). examshell is deliberately not offered.
# shellcheck shell=bash

FT_IDS=(norminette header42)
FT_MARK='" Installed by 42_custom_desktop (42 apps step); removed with it.'
NORMINETTE_VENV=/opt/42/norminette

# Version of the host's norminette, so the guest one matches the evaluations.
host_norminette_version() {
    command -v norminette >/dev/null || return 1
    norminette -v 2>/dev/null | sed -n 's/^norminette \([0-9][0-9.]*\).*/\1/p' | head -n1 | grep .
}

ft_desc() {
    local v
    case $1 in
        norminette)
            v=$(host_norminette_version) || v=latest
            echo "norminette $v (same version as this computer)" ;;
        header42) echo "42 header for vim/nvim (F1), also in host vim" ;;
    esac
}

# Packages the selected 42 apps need; the apps step must never remove them.
ft_apps_packages() {
    [[ " $(config_get FT_APPS) " == *" norminette "* ]] && echo python
    return 0
}

ft_install_norminette() {
    local rootfs=$1 v spec=norminette
    v=$(host_norminette_version) && spec="norminette==$v"
    if [[ -n $v ]] && compgen -G "$rootfs$NORMINETTE_VENV/lib/python*/site-packages/norminette-$v.dist-info" >/dev/null; then
        log "norminette $v already installed"
        return 0
    fi
    log "installing $spec in $NORMINETTE_VENV"
    guest_root pacman -S --needed --noconfirm python
    rm -rf "${rootfs:?}$NORMINETTE_VENV"
    guest python -m venv "$NORMINETTE_VENV"
    guest "$NORMINETTE_VENV/bin/pip" install --quiet --disable-pip-version-check "$spec"
    ln -sfn "$NORMINETTE_VENV/bin/norminette" "$rootfs/usr/local/bin/norminette"
}

ft_remove_norminette() {
    local rootfs=$1
    log "removing norminette"
    rm -rf "${rootfs:?}$NORMINETTE_VENV" "$rootfs/usr/local/bin/norminette"
    rmdir "$rootfs/opt/42" 2>/dev/null || true
}

# Campus mail domain from the sgoinfre NFS server (sgoinfre.42lyon.fr -> student.42lyon.fr).
_campus_mail() {
    local campus
    campus=$(findmnt -rno SOURCE /sgoinfre 2>/dev/null | sed -n 's/^sgoinfre\.\([^.:]*\)\..*/\1/p')
    echo "$USER@student.${campus:-42}.fr"
}

_header42_dirs() { printf '%s\n' "$HOME/.vim/plugin" "$HOME/.config/nvim/plugin"; }

ft_install_header42() {
    local src=$TMP_ROOT/makepkg/src/42header dir user mail
    # Defaults: what was entered last time (or a profile set), else this login.
    user=$(config_get HEADER42_USER)
    mail=$(config_get HEADER42_MAIL)
    user=$(ask_input "42 header" "Login shown in the header:" "${user:-$USER}") || die "aborted"
    mail=$(ask_input "42 header" "Mail shown in the header:" "${mail:-$(_campus_mail)}") || die "aborted"
    config_set HEADER42_USER "$user"
    config_set HEADER42_MAIL "$mail"
    log "installing the 42 header for vim/nvim"
    rm -rf "$src"
    git clone --quiet --depth 1 https://github.com/42Paris/42header "$src"
    while read -r dir; do
        mkdir -p "$dir"
        if [[ -e $dir/stdheader.vim && $(head -n1 "$dir/stdheader.vim") != "$FT_MARK" ]]; then
            warn "$dir/stdheader.vim exists and is not ours: left as is"
            continue
        fi
        { echo "$FT_MARK"; cat "$src/plugin/stdheader.vim"; } >"$dir/stdheader.vim"
        printf '%s\nlet g:user42 = %s\nlet g:mail42 = %s\n' "$FT_MARK" \
            "'${user//\'/\'\'}'" "'${mail//\'/\'\'}'" >"$dir/42header-user.vim"
    done < <(_header42_dirs)
    rm -rf "$src"
}

ft_remove_header42() {
    local dir f
    log "removing the 42 header"
    while read -r dir; do
        for f in "$dir/stdheader.vim" "$dir/42header-user.vim"; do
            [[ -e $f && $(head -n1 "$f") == "$FT_MARK" ]] && rm -f "$f"
        done
        # Folders this step created, if nothing else is in them.
        rmdir "$dir" "$(dirname "$dir")" 2>/dev/null || true
    done < <(_header42_dirs)
}

# choose_42apps: prints the selected ids, one per line.
choose_42apps() {
    local current id
    local -a items=()
    if ((ASSUME_YES)) && [[ -n ${FT_PRESET+x} ]]; then
        tr ' ' '\n' <<<"$FT_PRESET" | grep . || true
        return 0
    fi
    current=" $(config_get FT_APPS) "
    for id in "${FT_IDS[@]}"; do
        items+=("$id" "$(ft_desc "$id")" "$([[ $current == *" $id "* ]] && echo ON || echo OFF)")
    done
    ask_checklist "42 apps" "42 tools to have inside JuNest." "${items[@]}"
}

# setup_42apps <rootfs>
setup_42apps() {
    local rootfs=$1 out id current
    local -a selected=()
    out=$(choose_42apps) || die "aborted"
    [[ -n $out ]] && mapfile -t selected <<<"$out"
    current=" $(config_get FT_APPS) "
    for id in "${FT_IDS[@]}"; do
        if [[ " ${selected[*]} " == *" $id "* ]]; then
            "ft_install_$id" "$rootfs"
        elif [[ $current == *" $id "* ]]; then
            "ft_remove_$id" "$rootfs"
        fi
    done
    config_set FT_APPS "${selected[*]}"
    trim_rootfs "$rootfs"
    log "42 apps: ${selected[*]:-none}"
}
