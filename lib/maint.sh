# Maintenance: update (app, guest system, NVIDIA), doctor (checks, --fix),
# uninstall (everything 42desk put on the account, the user's files back).
# shellcheck shell=bash

DOCTOR_REPORT=$TMP_ROOT/doctor.txt
OUR_WRAPPERS=(junest junest-session junest-nvidia 42desk)

# ---------------------------------------------------------------- update

# _self_update: fast-forwards the repo 42desk runs from. Prints changed,
# same, or skipped: a development checkout (dirty, diverged, no upstream) is
# left alone.
_self_update() {
    local before after branch tag
    before=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null) || { warn "$REPO_DIR is not a git checkout: not updating 42desk"; echo skipped; return 0; }
    if [[ -n $(git -C "$REPO_DIR" status --porcelain --untracked-files=no) ]]; then
        warn "development checkout with local changes: update it with git yourself"
        echo skipped
        return 0
    fi
    log "checking for a new 42desk"
    git -C "$REPO_DIR" fetch --quiet --tags origin || { warn "could not reach the 42desk repository"; echo skipped; return 0; }
    if branch=$(git -C "$REPO_DIR" symbolic-ref --quiet --short HEAD); then
        if ! git -C "$REPO_DIR" rev-parse --quiet --verify "@{upstream}" >/dev/null; then
            warn "branch $branch tracks no remote branch: update it with git yourself"
            echo skipped
            return 0
        fi
        git -C "$REPO_DIR" merge --quiet --ff-only "@{upstream}" 2>/dev/null ||
            { warn "branch $branch has its own commits: update it with git yourself"; echo skipped; return 0; }
    else
        # Detached on a release tag: the newest release.
        tag=$(git -C "$REPO_DIR" tag --sort=-v:refname | head -n1)
        [[ -n $tag ]] && git -C "$REPO_DIR" -c advice.detachedHead=false checkout --quiet "$tag"
    fi
    after=$(git -C "$REPO_DIR" rev-parse HEAD)
    if [[ $before != "$after" ]]; then echo changed; else echo same; fi
}

# cmd_update [--self-only|--no-self] (UPDATE_SELF: all, only, no)
cmd_update() {
    local old new count self
    [[ -z ${JUNEST_ENV:-} ]] || die "run the update from the host, not inside JuNest"
    old=$(app_version)
    if [[ $UPDATE_SELF != no ]]; then
        self=$(_self_update)
        case $self in
            changed)
                log "42desk updated: $old -> $(app_version)"
                [[ $UPDATE_SELF == only ]] && return 0
                # The rest runs with the new code.
                local -a args=(update --no-self)
                ((ASSUME_YES)) && args+=(--yes)
                exec "$REPO_DIR/bin/42desk" "${args[@]}" ;;
            same) log "42desk is up to date ($old)" ;;
        esac
    fi
    [[ $UPDATE_SELF == only ]] && return 0

    prepare_existing
    configure_pacman "$ROOTFS"
    configure_makepkg "$ROOTFS"
    log "updating the JuNest system"
    guest_root pacman -Sy --needed --noconfirm archlinux-keyring
    count=$(guest_root pacman -Su --noconfirm | tee /dev/stderr | sed -n 's/^Packages (\([0-9]*\)).*/\1/p' | tail -n1)
    trim_rootfs "$ROOTFS"
    if [[ -r /sys/module/nvidia/version ]] && ! "$BIN_DIR/junest-nvidia" path >/dev/null 2>&1; then
        log "the NVIDIA driver changed: preparing $(cat /sys/module/nvidia/version)"
        "$BIN_DIR/junest-nvidia" fetch
    fi
    rice_refresh "$ROOTFS"
    profile_autosave
    new=$(app_version)
    [[ $new == "$old" ]] || new+=" (was $old)"
    log "update done: 42desk $new, ${count:-0} packages upgraded"
}

# ---------------------------------------------------------------- doctor

declare -a D_STATUS=() D_NAME=() D_MSG=() D_FIX=()

# check <name> PASS|WARN|FAIL <message> [<fix function>]
check() {
    D_NAME+=("$1") D_STATUS+=("$2") D_MSG+=("$3") D_FIX+=("${4:-}")
}

_fix_tmp()       { make_tmp_root; }
_fix_junest()    { rm -rf "$JUNEST_SRC"; install_junest; }
_fix_wrappers()  { install_wrappers; }
_fix_helpers()   { install_guest_helpers "$ROOTFS"; }
_fix_lock()      { rm -f "$ROOTFS/var/lib/pacman/db.lck"; }
_fix_pacman()    { configure_pacman "$ROOTFS"; }
_fix_nvidia()    { "$BIN_DIR/junest-nvidia" fetch; }
_fix_hook_on()   { install -d "$SHARE_DIR"; install -m 644 "$REPO_DIR/share/xsessionrc" "$SHARE_DIR/xsessionrc"; _set_login_hook 1; }
_fix_hook_off()  { _set_login_hook 0; }
_fix_rice()      { rice_refresh "$ROOTFS"; }

# _hook_present: the marked block is in ~/.xsessionrc.
_hook_present() { [[ -r $XSESSIONRC ]] && grep -qxF "$HOOK_BEGIN" "$XSESSIONRC"; }

run_checks() {
    local used tmp_mode f w ok desktop rice line rc p
    D_STATUS=() D_NAME=() D_MSG=() D_FIX=()
    ROOTFS=$(config_get JUNEST_HOME)
    desktop=$(config_get DESKTOP)
    rice=$(config_get RICE)

    used=$(df -P "$HOME" | awk 'NR == 2 { sub("%", "", $5); print $5 }')
    if ((used > 95)); then
        check "home space" FAIL "$used % used: free space (the rootfs is $(du -sh "$ROOTFS" 2>/dev/null | cut -f1)), or reinstall it in /goinfre"
    elif ((used > 80)); then
        check "home space" WARN "$used % used ($(free_gib "$HOME") GiB free)"
    else
        check "home space" PASS "$used % used ($(free_gib "$HOME") GiB free)"
    fi

    tmp_mode=$(stat -c '%a %U' "$TMP_ROOT" 2>/dev/null)
    if [[ $tmp_mode == "700 $USER" ]]; then
        check "/tmp/$USER" PASS "private (700)"
    elif [[ -e $TMP_ROOT && ! -O $TMP_ROOT ]]; then
        check "/tmp/$USER" FAIL "belongs to another user: ask staff to remove it"
    else
        check "/tmp/$USER" FAIL "${tmp_mode:-missing}: must be yours, mode 700" _fix_tmp
    fi

    if is_rootfs "$ROOTFS"; then
        check "rootfs" PASS "$ROOTFS ($(du -sh "$ROOTFS" 2>/dev/null | cut -f1))"
    else
        check "rootfs" FAIL "${ROOTFS:-not configured}: not installed on this computer; run 42desk install (it offers your saved profile)"
    fi

    if [[ $(git -C "$JUNEST_SRC" describe --tags 2>/dev/null) == "$JUNEST_VERSION" ]]; then
        check "JuNest" PASS "$JUNEST_VERSION in $JUNEST_SRC"
    else
        check "JuNest" FAIL "$JUNEST_SRC is missing or not $JUNEST_VERSION" _fix_junest
    fi

    ok=1
    for w in "${OUR_WRAPPERS[@]}"; do
        if [[ $w == 42desk ]]; then
            grep -qF "$REPO_DIR/bin/42desk" "$BIN_DIR/42desk" 2>/dev/null || ok=0
        else
            cmp -s "$REPO_DIR/bin/$w" "$BIN_DIR/$w" || ok=0
        fi
    done
    if ((ok)); then check "wrappers" PASS "up to date in $BIN_DIR"
    else check "wrappers" FAIL "missing or outdated in $BIN_DIR" _fix_wrappers; fi

    if is_rootfs "$ROOTFS"; then
        ok=1
        for f in "$REPO_DIR"/guest/*; do cmp -s "$f" "$ROOTFS/usr/local/bin/$(basename "$f")" || ok=0; done
        if ((ok)); then check "guest helpers" PASS "up to date"
        else check "guest helpers" FAIL "missing or outdated in the rootfs" _fix_helpers; fi
    fi

    if unshare --user --map-root-user true 2>/dev/null; then
        check "user namespaces" PASS "available"
    else
        check "user namespaces" FAIL "disabled on this computer: JuNest can't run (ask staff)"
    fi

    if is_rootfs "$ROOTFS"; then
        if line=$("$BIN_DIR/junest" -- true 2>&1); then
            check "JuNest runs" PASS "junest -- true works"
        else
            check "JuNest runs" FAIL "junest -- true failed: $(tail -n1 <<<"$line")"
        fi
        if [[ -e $ROOTFS/var/lib/pacman/db.lck ]]; then
            if pgrep -u "$USER" -x pacman >/dev/null; then
                check "pacman lock" WARN "pacman is running right now"
            else
                check "pacman lock" FAIL "stale lock (a pacman was interrupted)" _fix_lock
            fi
        else
            check "pacman lock" PASS "no lock"
        fi
        if grep -q "^CacheDir *= *$TMP_ROOT/pacman-cache/" "$ROOTFS/etc/pacman.conf"; then
            check "pacman cache" PASS "in $TMP_ROOT/pacman-cache"
        else
            check "pacman cache" FAIL "not in $TMP_ROOT (it would fill the rootfs)" _fix_pacman
        fi
    fi

    if [[ ! -r /sys/module/nvidia/version ]]; then
        check "NVIDIA" PASS "no NVIDIA driver on this computer"
    elif p=$("$BIN_DIR/junest-nvidia" path 2>/dev/null); then
        check "NVIDIA" PASS "$(cat /sys/module/nvidia/version) in $p"
    else
        check "NVIDIA" FAIL "libraries for $(cat /sys/module/nvidia/version) not prepared (software rendering)" _fix_nvidia
    fi

    if [[ -n $desktop ]]; then
        if _hook_present && cmp -s "$REPO_DIR/share/xsessionrc" "$SHARE_DIR/xsessionrc"; then
            check "login hook" PASS "$desktop starts at login"
        else
            check "login hook" FAIL "$desktop is set but won't start at login (~/.xsessionrc)" _fix_hook_on
        fi
    elif _hook_present; then
        check "login hook" FAIL "no desktop set, but ~/.xsessionrc still has the 42desk block" _fix_hook_off
    else
        check "login hook" PASS "no desktop: GNOME starts"
    fi
    if [[ -e $CONFIG_DIR/desktop-disabled ]]; then
        check "desktop disabled" WARN "$CONFIG_DIR/desktop-disabled exists: GNOME starts instead (rm it to re-enable)"
    fi

    while IFS= read -r p; do
        [[ -n $p ]] || continue
        if [[ -d $p ]]; then check "folder $p" PASS "bound in JuNest"
        else check "folder $p" WARN "missing on this computer (skipped by JuNest)"; fi
    done < <(config_get_array BINDS)

    if [[ -x /usr/local/bin/ft_lock ]]; then
        check "42 lock" PASS "ft_lock found"
    else
        check "42 lock" WARN "/usr/local/bin/ft_lock not found: Ctrl+Alt+L won't lock"
    fi
    if pgrep -f idle-watch.sh >/dev/null; then
        check "idle lock" PASS "42's idle-watch is running"
    else
        check "idle lock" WARN "42's idle-watch is not running: no lock when idle"
    fi

    if [[ -r $TMP_ROOT/desktop.log ]]; then
        rc=$(sed -n 's/^=== .* exited with status \([0-9]*\)$/\1/p' "$TMP_ROOT/desktop.log" | tail -n1)
        if [[ -n $rc && $rc != 0 ]]; then
            check "last session" WARN "the desktop exited with status $rc; end of $TMP_ROOT/desktop.log:"$'\n'"$(tail -n 10 "$TMP_ROOT/desktop.log" | sed 's/^/      /')"
        elif [[ -n $rc ]]; then
            check "last session" PASS "the desktop exited normally"
        fi
    fi

    if [[ -n $rice ]]; then
        ok=1
        if [[ -r $RICE_STATE/files ]]; then
            while IFS= read -r f; do is_ours "$f" || ok=0; done <"$RICE_STATE/files"
        else
            ok=0
        fi
        if ((ok)); then check "rice files" PASS "$rice"
        else check "rice files" FAIL "some $rice files are missing or were replaced" _fix_rice; fi
    fi
}

# print_checks: the report; returns the number of fixable problems in NFIX.
NFIX=0
print_checks() {
    local i c_ok=$'\e[32m' c_warn=$'\e[33m' c_fail=$'\e[31m' c_off=$'\e[0m' color mark
    [[ -t 1 ]] || c_ok='' c_warn='' c_fail='' c_off=''
    NFIX=0
    for i in "${!D_NAME[@]}"; do
        case ${D_STATUS[i]} in
            PASS) color=$c_ok ;;
            WARN) color=$c_warn ;;
            *) color=$c_fail ;;
        esac
        mark=" "
        if [[ ${D_STATUS[i]} != PASS && -n ${D_FIX[i]} ]]; then mark="*"; NFIX=$((NFIX + 1)); fi
        printf '%s%-4s%s %s %-18s %s\n' "$color" "${D_STATUS[i]}" "$c_off" "$mark" "${D_NAME[i]}" "${D_MSG[i]}"
    done
    ((NFIX)) && printf '\n* fixable: 42desk doctor --fix\n'
    return 0
}

run_fixes() {
    local i
    for i in "${!D_NAME[@]}"; do
        [[ ${D_STATUS[i]} != PASS && -n ${D_FIX[i]} ]] || continue
        log "fixing: ${D_NAME[i]}"
        "${D_FIX[i]}" || warn "could not fix ${D_NAME[i]}"
    done
}

# cmd_doctor [--fix] (DOCTOR_FIX)
cmd_doctor() {
    [[ -z ${JUNEST_ENV:-} ]] || die "run doctor from the host, not inside JuNest"
    make_tmp_root 2>/dev/null || true
    run_checks
    print_checks
    if ((DOCTOR_FIX && NFIX)); then
        ask_yesno "Doctor" "Fix the $NFIX fixable problems?" || return 0
        run_fixes
        echo
        run_checks
        print_checks
    fi
    [[ " ${D_STATUS[*]} " != *" FAIL "* ]]
}

# doctor_menu: the report in a scrollable box, then the offer to fix.
doctor_menu() {
    make_tmp_root
    run_checks
    print_checks >"$DOCTOR_REPORT"
    _wt --title "Doctor" --scrolltext --textbox "$DOCTOR_REPORT" 0 0 || true
    ((NFIX)) || return 0
    ask_yesno "Doctor" "Fix the $NFIX fixable problems (marked *)?" || return 0
    run_fixes
    run_checks
    print_checks >"$DOCTOR_REPORT"
    _wt --title "Doctor: after the fixes" --scrolltext --textbox "$DOCTOR_REPORT" 0 0 || true
}

# ---------------------------------------------------------------- uninstall

DESKTOP_CONFIG_DIRS=(i3 i3status bspwm sxhkd awesome xfce4 polybar picom rofi dunst xsettingsd)

cmd_uninstall() {
    local rootfs out p size msg drop_configs=0 drop_settings=0
    local -a remove=() left=()
    [[ -z ${JUNEST_ENV:-} ]] || die "run uninstall from the host, not inside JuNest"
    pgrep -u "$USER" -x bwrap >/dev/null && die "a JuNest session is running, close it first"
    rootfs=$(config_get JUNEST_HOME)

    out=$(ask_checklist "Uninstall" \
        "Removes JuNest, its rootfs, the desktop's login hook, the rice and 42 header files (your own files come back) and the NVIDIA libraries. Also:" \
        configs "Delete my desktop config folders (~/.config/i3, bspwm, polybar...)" OFF \
        settings "Delete my 42desk settings and saved profile" OFF) || die "aborted"
    [[ $out == *configs* ]] && drop_configs=1
    [[ $out == *settings* ]] && drop_settings=1

    is_rootfs "$rootfs" && remove+=("$rootfs ($(du -sh "$rootfs" 2>/dev/null | cut -f1))")
    for p in "$GOINFRE/junest-nvidia" "$HOME/.local/share/junest-nvidia" "$JUNEST_SRC" "$SHARE_DIR"; do
        [[ -e $p ]] && remove+=("$p")
    done
    for p in "${OUR_WRAPPERS[@]}"; do [[ -e $BIN_DIR/$p ]] && remove+=("$BIN_DIR/$p"); done
    ((drop_configs)) && for p in "${DESKTOP_CONFIG_DIRS[@]}"; do [[ -e $HOME/.config/$p ]] && remove+=("$HOME/.config/$p"); done
    ((drop_settings)) && remove+=("$CONFIG_DIR")
    msg="This deletes:"$'\n'
    for p in "${remove[@]}"; do msg+="  $p"$'\n'; done
    msg+=$'\n'"and the login hook, rice files, 42 header files and default-app files"$'\n'
    msg+="(your own files come back). The 42desk repo ($REPO_DIR) stays."$'\n\n'"Continue?"
    ((ASSUME_YES)) && printf '%s\n' "$msg" >&2
    ask_yesno "Uninstall" "$msg" || die "aborted"

    log "removing the login hook"
    _set_login_hook 0
    rm -rf "$SHARE_DIR"
    if [[ -n $(config_get RICE) || -r $RICE_STATE/files ]]; then
        log "removing the rice files"
        rice_remove_files
    fi
    [[ " $(config_get FT_APPS) " == *" header42 "* ]] && ft_remove_header42
    for p in "$HOME"/.config/*-mimeapps.list; do
        [[ -e $p && $(head -n1 "$p") == "$MIMEAPPS_MARK" ]] && rm -f "$p"
    done
    if is_rootfs "$rootfs"; then
        log "removing $rootfs"
        _remove_rootfs "$rootfs"
    fi
    rm -rf "$GOINFRE/junest-nvidia" "$HOME/.local/share/junest-nvidia" "$JUNEST_SRC"
    for p in "${OUR_WRAPPERS[@]}"; do rm -f "${BIN_DIR:?}/$p"; done
    rm -rf "${TMP_ROOT:?}"/{junest-setup,pacman-cache,makepkg,cache,nvidia} \
        "$TMP_ROOT"/{desktop.log,polybar.log,doctor.txt}
    if ((drop_configs)); then
        for p in "${DESKTOP_CONFIG_DIRS[@]}"; do rm -rf "${HOME:?}/.config/$p"; done
    fi
    if ((drop_settings)); then
        rm -rf "$CONFIG_DIR"
    else
        # A later install starts from scratch but offers the saved profile.
        config_set DESKTOP "" && config_set DESKTOP_START "" && config_set DESKTOP_NAME "" && config_set RICE ""
    fi

    # Anything of ours still there.
    for p in "${OUR_WRAPPERS[@]}"; do [[ -e $BIN_DIR/$p ]] && left+=("$BIN_DIR/$p"); done
    _hook_present && left+=("$XSESSIONRC (42desk block)")
    [[ -e $rootfs ]] && left+=("$rootfs")
    ((${#left[@]})) && warn "still there: ${left[*]}"
    size=$(free_gib "$HOME")
    log "uninstalled (home: $size GiB free)"
    ((drop_settings)) || log "your settings and saved profile stay in $CONFIG_DIR"
    log "to remove 42desk itself: rm -rf $REPO_DIR"
}
