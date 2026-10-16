# Shared constants and helpers. Sourced by install.sh, never run directly.
# shellcheck shell=bash disable=SC2034  # constants used by the other libs

JUNEST_VERSION=7.4.10
JUNEST_REPO=https://github.com/fsquillace/junest.git
JUNEST_SRC=$HOME/.local/share/junest
BIN_DIR=$HOME/.local/bin
CONFIG_DIR=$HOME/.config/42-junest
CONFIG_FILE=$CONFIG_DIR/config
DEFAULT_ROOTFS=$HOME/.junest
TMP_ROOT=/tmp/$USER
GOINFRE=/goinfre/$USER

# Set by install.sh flags.
ASSUME_YES=${ASSUME_YES:-0}

if [[ -t 1 ]]; then
    _c_info=$'\e[1;34m' _c_warn=$'\e[1;33m' _c_err=$'\e[1;31m' _c_off=$'\e[0m'
else
    _c_info='' _c_warn='' _c_err='' _c_off=''
fi

log()  { printf '%s==>%s %s\n' "$_c_info" "$_c_off" "$*" >&2; }
warn() { printf '%s==> warning:%s %s\n' "$_c_warn" "$_c_off" "$*" >&2; }
die()  { printf '%s==> error:%s %s\n' "$_c_err" "$_c_off" "$*" >&2; exit 1; }

have_whiptail() { [[ -t 0 && -t 1 ]] && command -v whiptail >/dev/null; }

# ask_yesno <title> <message>: 0 for yes. --yes answers yes to everything.
ask_yesno() {
    local title=$1 msg=$2 reply
    ((ASSUME_YES)) && return 0
    if have_whiptail; then
        whiptail --title "$title" --yesno "$msg" 0 0
        return
    fi
    printf '%s\n%s [y/N] ' "$title" "$msg" >&2
    read -r reply
    [[ $reply == [yY]* ]]
}

# ask_menu <title> <message> <default-tag> <tag> <label> [<tag> <label>...]
# Prints the chosen tag. --yes picks the default.
ask_menu() {
    local title=$1 msg=$2 def=$3 reply i
    shift 3
    if ((ASSUME_YES)); then echo "$def"; return 0; fi
    if have_whiptail; then
        whiptail --title "$title" --default-item "$def" --menu "$msg" 0 0 0 "$@" 3>&1 1>&2 2>&3
        return
    fi
    local items=("$@")
    printf '%s\n%s\n' "$title" "$msg" >&2
    for ((i = 0; i < ${#items[@]}; i += 2)); do
        printf '  %s) %s\n' "${items[i]}" "${items[i + 1]}" >&2
    done
    printf 'Choice [%s]: ' "$def" >&2
    read -r reply
    echo "${reply:-$def}"
}

# ask_input <title> <message> <default>: prints the entered text.
ask_input() {
    local title=$1 msg=$2 def=$3 reply
    if ((ASSUME_YES)); then echo "$def"; return 0; fi
    if have_whiptail; then
        whiptail --title "$title" --inputbox "$msg" 0 0 "$def" 3>&1 1>&2 2>&3
        return
    fi
    printf '%s\n%s [%s]: ' "$title" "$msg" "$def" >&2
    read -r reply
    echo "${reply:-$def}"
}

# Creates /tmp/$USER (mode 700) and refuses one owned by someone else.
make_tmp_root() {
    if [[ -e $TMP_ROOT && ! -O $TMP_ROOT ]]; then
        die "$TMP_ROOT exists but belongs to another user"
    fi
    install -d -m 700 "$TMP_ROOT"
    install -d -m 700 "$TMP_ROOT"/{junest-setup,pacman-cache,makepkg,cache,nvidia}
}

# Free space in GiB on the filesystem holding <path> (or its nearest parent).
free_gib() {
    local p=$1
    while [[ ! -e $p ]]; do p=$(dirname "$p"); done
    df -P --block-size=1G "$p" | awk 'NR==2 {print $4}'
}

# True if <dir> looks like a JuNest/Arch rootfs, so it is safe to delete.
is_rootfs() {
    [[ -x $1/usr/bin/pacman && -f $1/etc/pacman.conf ]]
}
