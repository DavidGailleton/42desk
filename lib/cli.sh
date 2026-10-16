# 42desk commands: install, configure <step>, status, and the control center
# menu (no command). Sourced by bin/42desk after the other libs.
# shellcheck shell=bash

CONFIG_SCHEMA=1  # current CONFIG_VERSION; not named like the key (config_get would read it)
STEPS=(folders desktop rice apps 42apps)

usage() {
    cat >&2 <<'EOF'
Usage: 42desk [COMMAND] [OPTIONS]

Commands:
  (none)                 control center menu
  install                fresh install (wipes any previous setup after a confirmation)
  configure STEP         change one step: folders, desktop, rice, apps, 42apps
  rice [ID|stock]        change the look (menu without ID); works inside the desktop too
  rice --list            rices for the current desktop: id, then name
  profile export [FILE]  save the setup to FILE (default: print it)
  profile import P       apply profile P (a file, saved, or a bundled name) to the install
  profile list           the bundled profiles
  status                 show the current setup
  update [--self-only|--no-self]
                         update 42desk, the JuNest system and the NVIDIA libraries
  doctor [--fix]         check the setup; --fix repairs what it can (marked *)
  uninstall              remove everything 42desk installed (your own files come back)

Options:
  --rootfs PATH          install: where to create the rootfs (otherwise asked)
  --desktop ID|none      install, configure desktop: i3, bspwm, awesome, xfce or none
  --rice ID|stock        install, configure rice: the look (see rice --list)
  --profile P            install: answer every step from profile P (see profile)
  -y, --yes              never ask: take the defaults or the current choices
  -h, --help             this help
EOF
    exit "${1:-0}"
}

ROOTFS="" DESKTOP_CHOICE="" RICE_CHOICE="" PROFILE_ARG="" UPDATE_SELF=all DOCTOR_FIX=0

# parse_options <arg>...: global options; the other words land in ARGS.
ARGS=()
# shellcheck disable=SC2034  # the flags are read by lib/maint.sh and lib/rice.sh
parse_options() {
    while (($#)); do
        case "$1" in
            --rootfs) ROOTFS=${2:?--rootfs needs a path}; shift 2 ;;
            --desktop) DESKTOP_CHOICE=${2:?--desktop needs an id}; shift 2 ;;
            --rice) RICE_CHOICE=${2:?--rice needs an id}; shift 2 ;;
            --profile) PROFILE_ARG=${2:?--profile needs a file or name}; shift 2 ;;
            # Old install.sh flag.
            --step) ARGS=(configure "${2:?--step needs a name}" "${ARGS[@]}"); shift 2 ;;
            -y|--yes) ASSUME_YES=1; shift ;;
            -h|--help) usage ;;
            --list) ARGS+=("$1"); shift ;;  # rice --list
            --fix) DOCTOR_FIX=1; shift ;;
            --self-only) UPDATE_SELF=only; shift ;;
            --no-self) UPDATE_SELF=no; shift ;;
            -*) warn "unknown option: $1"; usage 1 ;;
            *) ARGS+=("$1"); shift ;;
        esac
    done
}

# Config files from before CONFIG_VERSION need nothing yet: only the key.
migrate_config() {
    local v
    v=$(config_get CONFIG_VERSION)
    [[ ${v:-0} -lt $CONFIG_SCHEMA ]] && config_set CONFIG_VERSION "$CONFIG_SCHEMA"
    return 0
}

preflight() {
    local cmd
    ((EUID != 0)) || die "run this as your normal user, not root"
    [[ -z ${JUNEST_ENV:-} ]] || die "run this from the host, not inside JuNest"
    for cmd in git curl readelf flock unshare; do
        command -v "$cmd" >/dev/null || die "missing host command: $cmd"
    done
    unshare --user --map-root-user true 2>/dev/null ||
        die "unprivileged user namespaces are disabled, JuNest ns mode cannot work"
    make_tmp_root
    (($(free_gib "$TMP_ROOT") >= 3)) || die "less than 3 GiB free in /tmp"
}

choose_rootfs() {
    local choice
    if [[ -z $ROOTFS ]]; then
        choice=$(ask_menu "JuNest location" \
            "Where should the JuNest rootfs live?" home \
            home    "$DEFAULT_ROOTFS  (kept when changing computer, uses home quota)" \
            goinfre "$GOINFRE/junest  (fast, no quota, this computer only)" \
            custom  "Another path") || die "aborted"
        case "$choice" in
            home)    ROOTFS=$DEFAULT_ROOTFS ;;
            goinfre) ROOTFS=$GOINFRE/junest ;;
            custom)  ROOTFS=$(ask_input "JuNest location" "Absolute path of the rootfs:" "$DEFAULT_ROOTFS") ||
                         die "aborted" ;;
            *)       die "unknown choice: $choice" ;;
        esac
    fi
    [[ $ROOTFS == /* ]] || die "rootfs path must be absolute: $ROOTFS"
    [[ $ROOTFS != *[[:space:]]* ]] || die "rootfs path must not contain spaces: $ROOTFS"
    ROOTFS=$(realpath -m "$ROOTFS")
    case "$ROOTFS" in
        / | "$HOME" | /goinfre | /sgoinfre) die "refusing rootfs path: $ROOTFS" ;;
        /tmp | /tmp/*) die "/tmp is wiped at reboot, pick another rootfs path" ;;
    esac
    log "rootfs: $ROOTFS"
}

# The rootfs of the existing install, or die.
existing_rootfs() {
    ROOTFS=$(config_get JUNEST_HOME)
    is_rootfs "$ROOTFS" || die "no JuNest install found, run 42desk install first"
}

app_version() {
    git -C "$REPO_DIR" describe --tags --always --dirty 2>/dev/null || echo unknown
}

# status_text: the current setup, one "label: value" per line.
status_text() {
    local rootfs size binds nv
    rootfs=$(config_get JUNEST_HOME)
    if is_rootfs "$rootfs"; then
        size=$(du -sh "$rootfs" 2>/dev/null | cut -f1)
    else
        size="not installed on this computer"
    fi
    binds=$(config_get_array BINDS | paste -sd' ')
    nv=$("$BIN_DIR/junest-nvidia" path 2>/dev/null || echo 'not prepared on this computer')
    [[ -r /sys/module/nvidia/version ]] || nv="no NVIDIA GPU"
    printf '%-12s %s\n' \
        "42desk:" "$(app_version) ($REPO_DIR)" \
        "rootfs:" "${rootfs:-none} ($size)" \
        "desktop:" "$(config_get DESKTOP_NAME | grep . || echo 'none (GNOME)')" \
        "rice:" "$(config_get RICE | grep . || echo stock)" \
        "apps:" "$(config_get APPS | grep . || echo none)" \
        "folders:" "${binds:-none}" \
        "42 apps:" "$(config_get FT_APPS | grep . || echo none)" \
        "NVIDIA:" "$nv" \
        "home free:" "$(free_gib "$HOME") GiB" \
        "caches:" "$TMP_ROOT"
}

cmd_status() { status_text; }

cmd_install() {
    local profile=""
    preflight
    if [[ -n $PROFILE_ARG ]]; then
        profile=$(profile_resolve "$PROFILE_ARG")
    elif ((!ASSUME_YES)); then
        profile=$(choose_profile)
    fi
    [[ -z $profile ]] || confirm_profile "$profile"
    choose_rootfs
    cleanup_old "$ROOTFS"
    (($(free_gib "$ROOTFS") >= 4)) || die "less than 4 GiB free for $ROOTFS"

    install_junest
    install_wrappers
    write_config "$ROOTFS"
    migrate_config
    setup_rootfs "$ROOTFS"

    configure_pacman "$ROOTFS"
    configure_makepkg "$ROOTFS"
    remove_yay
    install_base_packages "$ROOTFS"
    install_guest_helpers "$ROOTFS"
    configure_timezone "$ROOTFS"

    if [[ -r /sys/module/nvidia/version ]]; then
        log "preparing NVIDIA $(cat /sys/module/nvidia/version) userspace libraries"
        "$BIN_DIR/junest-nvidia" fetch
    fi

    local step
    [[ -z $profile ]] || profile_presets
    for step in "${STEPS[@]}"; do run_step "$step"; done

    trim_rootfs "$ROOTFS"
    log "done"
    status_text >&2
    printf '%-12s %s\n' "start with:" "junest, or 42desk to change the setup" >&2
}

run_step() {
    case "$1" in
        folders) setup_folders "$ROOTFS" ;;
        desktop) setup_desktop "$ROOTFS" "$DESKTOP_CHOICE" ;;
        rice)    setup_rice "$ROOTFS" ;;
        apps)    setup_apps "$ROOTFS" ;;
        42apps)  setup_42apps "$ROOTFS" ;;
        *) die "unknown step: $1 (one of: ${STEPS[*]})" ;;
    esac
    profile_autosave
}

# cmd_configure <step>: re-runs one step on the existing install.
cmd_configure() {
    local step=${1:-}
    [[ -n $step ]] || die "configure needs a step: ${STEPS[*]}"
    [[ " ${STEPS[*]} " == *" $step "* ]] || die "unknown step: $step (one of: ${STEPS[*]})"
    require_whiptail
    prepare_existing
    run_step "$step"
}

# prepare_existing: the existing install, refreshed with what the repo
# installs, in case it changed since the install.
prepare_existing() {
    existing_rootfs
    make_tmp_root
    install_wrappers
    install_guest_helpers "$ROOTFS"
    configure_timezone "$ROOTFS"
    migrate_config
}

# cmd_profile export [FILE] | import P | list
cmd_profile() {
    local action=${1:-} arg=${2:-} file name
    case $action in
        export)
            [[ -r $CONFIG_FILE ]] || die "nothing to export: no setup yet"
            if [[ -z $arg ]]; then
                file=$(mktemp "$TMP_ROOT/profile.XXXXXX")
                profile_write "$file" "exported setup"
                cat "$file"
                rm -f "$file"
            else
                profile_write "$arg"
                log "profile saved to $arg (share it, or: 42desk profile import $arg)"
            fi ;;
        import)
            [[ -n $arg ]] || die "profile import needs a file, saved, or one of: $(profile_names | paste -sd' ')"
            require_whiptail
            file=$(profile_resolve "$arg")
            prepare_existing
            confirm_profile "$file"
            profile_presets
            for name in "${STEPS[@]}"; do run_step "$name"; done
            log "profile applied: ${PROFILE[PROFILE_NAME]:-$(basename "$file")}" ;;
        list)
            for name in $(profile_names); do
                printf '%-14s %s\n' "$name" "$(sed -n 's/^PROFILE_NAME=//p' "$PROFILE_DIR/$name.profile")"
            done ;;
        *) die "profile needs export, import or list" ;;
    esac
}

# Control center's profile submenu.
profile_menu() {
    local choice path name
    local -a items=()
    choice=$(ask_menu "Profiles"         "A profile holds your whole setup (desktop, rice, apps, folders, 42 apps) in one file. It is saved automatically to $SAVED_PROFILE after every change."         export         export "Save my setup to a file (to share or keep)"         import "Apply a profile to this install") || return 0
    case $choice in
        export)
            path=$(ask_input "Export" "File to write:" "$HOME/42desk.profile") || return 0
            cmd_profile export "${path/#\~/$HOME}" ;;
        import)
            [[ -f $SAVED_PROFILE ]] && items+=(saved "Your saved setup")
            for name in $(profile_names); do
                items+=("$name" "$(sed -n 's/^PROFILE_NAME=//p' "$PROFILE_DIR/$name.profile")")
            done
            items+=(file "A profile file...")
            choice=$(ask_menu "Import" "Which profile?" "${items[0]}" "${items[@]}") || return 0
            if [[ $choice == file ]]; then
                choice=$(ask_input "Import" "Path of the profile file:" "$HOME/") || return 0
                choice=${choice/#\~/$HOME}
            fi
            cmd_profile import "$choice" ;;
    esac
}

# cmd_rice [ID|stock|--list]
cmd_rice() {
    local desktop id
    desktop=$(config_get DESKTOP)
    if [[ ${1:-} == --list ]]; then
        [[ -n $desktop ]] || return 0
        printf 'stock\tStock\n'
        for id in $(rice_ids "$desktop"); do printf '%s\t%s\n' "$id" "$(rice_field "$id" NAME)"; done
        return 0
    fi
    [[ -n $desktop ]] || die "no desktop configured: run 42desk configure desktop first"
    if [[ -n ${1:-} ]]; then
        # shellcheck disable=SC2034  # read by choose_rice (lib/rice.sh)
        RICE_CHOICE=$1
        ASSUME_YES=1
    fi
    cmd_configure rice
}

# Control center: one menu, each action in a subshell so that a failure or an
# "aborted" brings the menu back instead of quitting.
cmd_menu() {
    local choice last=status rc
    local -a items
    require_whiptail
    while :; do
        items=(status "Show the current setup")
        if is_rootfs "$(config_get JUNEST_HOME)"; then
            items+=(
                desktop "Change the desktop environment"
                rice    "Change the look (rice or stock)"
                apps    "Change the apps and default apps"
                folders "Change the host folders visible in JuNest"
                42apps  "Change the 42 apps (norminette, 42 header)"
                profile "Save or apply a profile (whole setup in one file)"
                update  "Update 42desk, the JuNest system and the NVIDIA libraries"
                doctor  "Check the setup and fix problems"
                install "Reinstall from scratch"
                uninstall "Remove everything 42desk installed"
            )
        else
            items+=(
                install "Install JuNest and a custom desktop"
                doctor  "Check why it isn't installed or doesn't work"
            )
            last=install
        fi
        items+=(quit "Quit")
        choice=$(ask_menu "42desk $(app_version)" "What do you want to do?" "$last" "${items[@]}") || return 0
        last=$choice
        rc=0
        case "$choice" in
            quit) return 0 ;;
            status) _wt --title "Status" --msgbox "$(status_text)" 0 0 || true; continue ;;
            install) (cmd_install) || rc=$? ;;
            profile) (profile_menu) || rc=$? ;;
            update) (cmd_update) || rc=$? ;;
            doctor) (doctor_menu) || rc=$?; continue ;;
            uninstall) (cmd_uninstall) || rc=$? ;;
            *) (cmd_configure "$choice") || rc=$? ;;
        esac
        if ((rc)); then
            _wt --title "42desk" --msgbox "\"$choice\" stopped (status $rc). The messages above say why." 0 0 || true
        else
            _wt --title "42desk" --msgbox "\"$choice\" done." 0 0 || true
        fi
    done
}

main() {
    parse_options "$@"
    set -- "${ARGS[@]}"
    local cmd=${1:-}
    (($#)) && shift
    case "$cmd" in
        "")
            # Nothing to ask with --yes: just show the setup.
            if ((ASSUME_YES)); then cmd_status; else cmd_menu; fi ;;
        install)   require_whiptail; cmd_install ;;
        configure) cmd_configure "$@" ;;
        status)    cmd_status ;;
        rice)      cmd_rice "$@" ;;
        profile)   cmd_profile "$@" ;;
        update)    cmd_update ;;
        doctor)    cmd_doctor ;;
        uninstall) require_whiptail; cmd_uninstall ;;
        help)      usage ;;
        *) warn "unknown command: $cmd"; usage 1 ;;
    esac
}
