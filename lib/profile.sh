# Profiles: a whole setup (desktop, rice, apps, folders, 42 apps) in one file,
# to reinstall it in one go or share it. Profiles come from other students, so
# they are parsed, never sourced: only known keys, only plain values.
# shellcheck shell=bash

PROFILE_DIR=$REPO_DIR/profiles
SAVED_PROFILE=$CONFIG_DIR/profile
PROFILE_MARK="# 42desk profile"
# Keys a profile may set; a missing key keeps that step's current choice.
PROFILE_KEYS=(PROFILE_NAME DESKTOP RICE APPS BINDS FT_APPS HEADER42_USER HEADER42_MAIL
    DEFAULT_TERMINAL DEFAULT_BROWSER DEFAULT_EDITOR DEFAULT_FILES DEFAULT_VIDEO DEFAULT_IMAGE DEFAULT_PDF)

declare -A PROFILE=()

# _anon_path <path>: path components equal to the login become @USER@.
_anon_path() {
    local IFS=/ i
    local -a parts
    read -ra parts <<<"$1"
    for i in "${!parts[@]}"; do
        [[ ${parts[i]} == "$USER" ]] && parts[i]=@USER@
    done
    echo "${parts[*]}"
}

# profile_write <file> [<name>]: the current setup, with the login as @USER@.
profile_write() {
    local file=$1 name=${2:-} role v p binds="" user mail
    [[ -n $name ]] || name=$(basename "$file" .profile)
    for p in $(config_get_array BINDS); do binds+="$(_anon_path "$p") "; done
    user=$(config_get HEADER42_USER)
    mail=$(config_get HEADER42_MAIL)
    [[ $user == "$USER" ]] && user=@USER@
    [[ $mail == "$USER@"* ]] && mail=@USER@${mail#"$USER"}
    {
        echo "$PROFILE_MARK: plain KEY=value lines, read by 42desk (never run)."
        echo "# @USER@ stands for the login of whoever installs it. A missing key keeps"
        echo "# that step's current choice. Made by 42desk $(app_version) on $(date +%F)."
        echo "PROFILE_NAME=$name"
        v=$(config_get DESKTOP); echo "DESKTOP=${v:-none}"
        v=$(config_get RICE); echo "RICE=${v:-stock}"
        echo "APPS=$(config_get APPS)"
        for role in "${ROLE_ORDER[@]}"; do
            v=$(config_get "DEFAULT_${role^^}")
            [[ -n $v ]] && echo "DEFAULT_${role^^}=$v"
        done
        echo "BINDS=${binds% }"
        echo "FT_APPS=$(config_get FT_APPS)"
        [[ -n $user ]] && echo "HEADER42_USER=$user"
        [[ -n $mail ]] && echo "HEADER42_MAIL=$mail"
    } >"$file.tmp"
    mv "$file.tmp" "$file"
}

# profile_resolve <file|name|saved>: prints the profile's path.
profile_resolve() {
    local p=$1
    if [[ $p == saved ]]; then
        p=$SAVED_PROFILE
    elif [[ ! -f $p && -f $PROFILE_DIR/$p.profile ]]; then
        p=$PROFILE_DIR/$p.profile
    fi
    [[ -f $p ]] || die "no such profile: $1 (a file, saved, or one of: $(profile_names | paste -sd' '))"
    realpath -- "$p"
}

profile_names() {
    local f
    for f in "$PROFILE_DIR"/*.profile; do basename "$f" .profile; done
}

# profile_load <file>: fills PROFILE. Unknown keys and odd values are refused,
# unknown ids (an app no longer in the catalog) are dropped with a warning.
profile_load() {
    local file=$1 line key val id n=0 plain='^[A-Za-z0-9 ._@/+:,-]*$'
    local -a kept
    PROFILE=()
    head -n1 "$file" | grep -q "^$PROFILE_MARK" || die "$file is not a 42desk profile"
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line == *=* ]] || die "$file:$n: expected KEY=value"
        key=${line%%=*} val=${line#*=}
        [[ " ${PROFILE_KEYS[*]} " == *" $key "* ]] || die "$file:$n: unknown key: $key"
        [[ $val =~ $plain ]] || die "$file:$n: unexpected characters in $key"
        PROFILE[$key]=${val//@USER@/$USER}
    done <"$file"

    if [[ -n ${PROFILE[DESKTOP]+x} && ${PROFILE[DESKTOP]} != none && ! -f $DESKTOP_DIR/${PROFILE[DESKTOP]}.conf ]]; then
        warn "unknown desktop in the profile: ${PROFILE[DESKTOP]} (keeping GNOME only)"
        PROFILE[DESKTOP]=none
    fi
    if [[ -n ${PROFILE[RICE]+x} && ${PROFILE[RICE]} != stock ]]; then
        if [[ ! -d $RICE_DIR/${PROFILE[RICE]} ]]; then
            warn "unknown rice in the profile: ${PROFILE[RICE]} (stock look)"
            PROFILE[RICE]=stock
        elif [[ ${PROFILE[DESKTOP]:-} == none ]]; then
            PROFILE[RICE]=stock
        fi
    fi
    if [[ -n ${PROFILE[APPS]+x} ]]; then
        load_catalog
        kept=()
        for id in ${PROFILE[APPS]}; do
            if [[ -n ${APP_PKGS[$id]+x} ]]; then kept+=("$id"); else warn "unknown app in the profile: $id (skipped)"; fi
        done
        PROFILE[APPS]=${kept[*]}
    fi
    if [[ -n ${PROFILE[FT_APPS]+x} ]]; then
        kept=()
        for id in ${PROFILE[FT_APPS]}; do
            if [[ " ${FT_IDS[*]} " == *" $id "* ]]; then kept+=("$id"); else warn "unknown 42 app in the profile: $id (skipped)"; fi
        done
        PROFILE[FT_APPS]=${kept[*]}
    fi
}

# profile_summary: what the loaded profile sets, for a confirmation.
profile_summary() {
    local k label
    for k in DESKTOP RICE APPS BINDS FT_APPS; do
        [[ -n ${PROFILE[$k]+x} ]] || continue
        case $k in
            BINDS) label=folders ;;
            FT_APPS) label="42 apps" ;;
            *) label=${k,,} ;;
        esac
        printf '%-9s %s\n' "$label:" "${PROFILE[$k]:-none}"
    done
}

# profile_presets: turns the loaded profile into the steps' --yes presets.
# Steps whose key is missing keep their current choice.
profile_presets() {
    local k
    # shellcheck disable=SC2034  # read by the steps (lib/*.sh)
    {
        [[ -n ${PROFILE[DESKTOP]+x} ]] && DESKTOP_CHOICE=${PROFILE[DESKTOP]}
        [[ -n ${PROFILE[RICE]+x} ]] && RICE_CHOICE=${PROFILE[RICE]}
        [[ -n ${PROFILE[BINDS]+x} ]] && FOLDERS_PRESET=${PROFILE[BINDS]}
        [[ -n ${PROFILE[APPS]+x} ]] && APPS_PRESET=${PROFILE[APPS]}
        [[ -n ${PROFILE[FT_APPS]+x} ]] && FT_PRESET=${PROFILE[FT_APPS]}
    }
    # Read by the steps from the config: the default apps' radiolists and the
    # 42 header's inputboxes take the current value with --yes.
    for k in HEADER42_USER HEADER42_MAIL DEFAULT_TERMINAL DEFAULT_BROWSER DEFAULT_EDITOR \
        DEFAULT_FILES DEFAULT_VIDEO DEFAULT_IMAGE DEFAULT_PDF; do
        [[ -n ${PROFILE[$k]+x} ]] && config_set "$k" "${PROFILE[$k]}"
    done
    # shellcheck disable=SC2034  # read by every ask_* (lib/common.sh)
    ASSUME_YES=1
}

# profile_autosave: after every step, so a new computer can get the same setup.
profile_autosave() {
    [[ -r $CONFIG_FILE ]] || return 0
    profile_write "$SAVED_PROFILE" "saved setup"
}

# choose_profile: for a fresh install, prints a profile path, or nothing to
# answer the questions.
choose_profile() {
    local name choice path
    local -a items=(questions "Answer the questions (custom setup)")
    [[ -f $SAVED_PROFILE ]] && items+=(saved "Your saved setup (as of your last change)")
    for name in $(profile_names); do
        items+=("$name" "$(sed -n 's/^PROFILE_NAME=//p' "$PROFILE_DIR/$name.profile")")
    done
    items+=(file "A profile file...")
    choice=$(ask_menu "Profile" "Start from a profile? It answers every question after the rootfs location." \
        questions "${items[@]}") || die "aborted"
    case $choice in
        questions) return 0 ;;
        file) path=$(ask_input "Profile" "Path of the profile file:" "$HOME/") || die "aborted"
              profile_resolve "${path/#\~/$HOME}" ;;
        *) profile_resolve "$choice" ;;
    esac
}

# confirm_profile <file>: loads it and asks.
confirm_profile() {
    profile_load "$1"
    ask_yesno "Profile: ${PROFILE[PROFILE_NAME]:-$(basename "$1")}" \
        "$(profile_summary)"$'\n\n'"Missing entries keep the current choice. Use this profile?" || die "aborted"
}
