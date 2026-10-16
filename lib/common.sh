# Shared constants and helpers. Sourced by bin/42desk, never run directly.
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

# Set by the --yes flag.
ASSUME_YES=${ASSUME_YES:-0}

if [[ -t 1 ]]; then
    _c_info=$'\e[1;34m' _c_warn=$'\e[1;33m' _c_err=$'\e[1;31m' _c_off=$'\e[0m'
else
    _c_info='' _c_warn='' _c_err='' _c_off=''
fi

log()  { printf '%s==>%s %s\n' "$_c_info" "$_c_off" "$*" >&2; }
warn() { printf '%s==> warning:%s %s\n' "$_c_warn" "$_c_off" "$*" >&2; }
die()  { printf '%s==> error:%s %s\n' "$_c_err" "$_c_off" "$*" >&2; exit 1; }

# Every question goes through whiptail. It draws on stderr (stdout is often
# captured by $(...)), so stdin and stderr must be a terminal. --yes never asks.
require_whiptail() {
    ((ASSUME_YES)) && return 0
    command -v whiptail >/dev/null || die "whiptail is required for the questions (or use --yes)"
    [[ -t 0 && -t 2 ]] || die "run this from a terminal to answer the questions (or use --yes)"
}

# whiptail with its answer on stdout and its screen on stderr.
_wt() { whiptail "$@" 3>&1 1>&2 2>&3; }

# ask_yesno <title> <message>: 0 for yes. --yes answers yes.
ask_yesno() {
    ((ASSUME_YES)) && return 0
    require_whiptail
    _wt --title "$1" --yesno "$2" 0 0
}

# ask_menu <title> <message> <default-tag> <tag> <label>...: prints the chosen tag.
# --yes picks the default.
ask_menu() {
    local title=$1 msg=$2 def=$3
    shift 3
    if ((ASSUME_YES)); then echo "$def"; return 0; fi
    require_whiptail
    _wt --title "$title" --default-item "$def" --menu "$msg" 0 0 0 "$@"
}

# ask_input <title> <message> <default>: prints the entered text.
ask_input() {
    if ((ASSUME_YES)); then echo "$3"; return 0; fi
    require_whiptail
    _wt --title "$1" --inputbox "$2" 0 0 "$3"
}

# ask_checklist <title> <message> <tag> <label> <ON|OFF>...: prints the
# checked tags, one per line. --yes keeps the items given as ON.
ask_checklist() {
    local title=$1 msg=$2 i
    shift 2
    if ((ASSUME_YES)); then
        local items=("$@")
        for ((i = 0; i < ${#items[@]}; i += 3)); do
            [[ ${items[i + 2]} == ON ]] && echo "${items[i]}"
        done
        return 0
    fi
    require_whiptail
    _wt --title "$title" --separate-output --checklist "$msg" 0 0 0 "$@"
}

# ask_radiolist <title> <message> <tag> <label> <ON|OFF>...: prints the chosen
# tag. --yes keeps the item given as ON (or the first one).
ask_radiolist() {
    local title=$1 msg=$2 i
    shift 2
    if ((ASSUME_YES)); then
        local items=("$@")
        for ((i = 0; i < ${#items[@]}; i += 3)); do
            [[ ${items[i + 2]} == ON ]] && { echo "${items[i]}"; return 0; }
        done
        echo "${items[0]}"
        return 0
    fi
    require_whiptail
    _wt --title "$title" --radiolist "$msg" 0 0 0 "$@"
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

# config_set <KEY> <value>: sets KEY=value (shell-quoted) in the config file,
# replacing an existing KEY= line or appending one. Other lines are kept.
config_set() {
    _config_write_line "$1" "$1=$(printf '%q' "$2")"
}

# config_set_array <KEY> [<value>...]: sets KEY=(v1 v2 ...), each shell-quoted.
config_set_array() {
    local key=$1 vals=""
    shift
    (($#)) && vals=$(printf '%q ' "$@")
    _config_write_line "$key" "$key=(${vals% })"
}

# config_has <KEY>: true if the config file sets KEY at all.
config_has() { [[ -r $CONFIG_FILE ]] && grep -q "^$1=" "$CONFIG_FILE"; }

# config_get_array <KEY>: prints the elements of the array KEY, one per line.
config_get_array() {
    [[ -r $CONFIG_FILE ]] || return 0
    # shellcheck source=/dev/null
    (. "$CONFIG_FILE" && eval '((${#'"$1"'[@]})) && printf "%s\n" "${'"$1"'[@]}"') || true
}

_config_write_line() {
    local tmp
    mkdir -p "$CONFIG_DIR"
    [[ -e $CONFIG_FILE ]] ||
        echo "# Written by 42desk, read by ~/.local/bin/junest." >"$CONFIG_FILE"
    tmp=$(mktemp "$CONFIG_FILE.XXXXXX")
    # Through ENVIRON: awk -v would eat the backslashes of the %q quoting.
    KEY=$1 LINE=$2 awk '
        index($0, ENVIRON["KEY"] "=") == 1 { if (!done) print ENVIRON["LINE"]; done = 1; next }
        { print }
        END { if (!done) print ENVIRON["LINE"] }' "$CONFIG_FILE" >"$tmp"
    mv "$tmp" "$CONFIG_FILE"
}

# config_get <KEY>: prints the value of KEY from the config file (empty if unset).
config_get() {
    [[ -r $CONFIG_FILE ]] || return 0
    # shellcheck source=/dev/null
    (. "$CONFIG_FILE" && printf '%s' "${!1:-}")
}

# True if <dir> looks like a JuNest/Arch rootfs, so it is safe to delete.
is_rootfs() {
    [[ -x $1/usr/bin/pacman && -f $1/etc/pacman.conf ]]
}
