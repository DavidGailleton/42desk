# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Goal

An interactive Bash script (whiptail menus) that sets up a customized [JuNest](https://github.com/fsquillace/junest) environment (Arch Linux in userspace, no root) on a 42 school computer. Planned questions, built on top of the base install:

1. Whether to install a desktop environment, which then starts **before** the host's 42 desktop session (GNOME).
2. Pre-made "rice" config or stock configs (with a choice among options).
3. Which host folders to pass through into JuNest (e.g. `/goinfre`, `/sgoinfre`).
4. Which apps to install, grouped by category.
5. When both a desktop environment and an app in a category are selected, which app is the default for that category.
6. Which 42-specific apps should be available inside JuNest.

Done so far: the `42desk` command and control center, the base install, and all six steps: the desktop (i3, bspwm, awesome or XFCE, all native X11), the rice (our own themes), host folders, apps by category, the default app per role, and the 42 apps (norminette, 42 header), plus profiles (the whole setup in one shareable file). `42_bspwm_dotfile/` (a separate repo, excluded in `.git/info/exclude`) is not used: its rices need the AUR and chaotic-aur, and its `LD_PRELOAD` trick against `ft_lock`'s timers must never be carried over. Hyprland and other Wayland compositors can't work here: the display manager's Xorg owns the GPU, and Hyprland has no X11 backend.

## Commands

- Control center (whiptail menu): `42desk`, or `bin/42desk` from the repo. `42desk status` prints the setup; `42desk --help` lists the commands.
- Install (fresh: wipes any previous setup after a confirmation): `./install.sh [--rootfs PATH] [--desktop ID|none] [--yes]`, the same as `bin/42desk install …`.
- Re-run one step on the existing install: `42desk configure desktop [--desktop i3|bspwm|awesome|xfce|none]`; also `configure folders`, `configure apps`, `configure 42apps`. `./install.sh --step X` is an alias. The full install runs folders → desktop → apps → 42apps.
- Test the apps step without menus: `APPS_PRESET="alacritty firefox" ./install.sh --step apps --yes`. The preset only applies with `--yes`, even empty; the same goes for `FOLDERS_PRESET` and `FT_PRESET`. A profile with `--yes` drives every step the same way.
- Profiles: `42desk profile export [FILE]`, `42desk profile import FILE|saved|NAME`, `42desk profile list`, `42desk install --profile FILE|NAME`. Bundled ones are in `profiles/`.
- Change the look: `42desk rice ID|stock` (also from a terminal inside the desktop, or Super+Shift+T there); `42desk rice --list`; `42desk configure rice` for the menu; `--rice ID|stock` for `install`/`configure`.
- Try the configured desktop without logging out: `Xephyr :5 -screen 1600x900 -noreset & DISPLAY=:5 junest-session --nested` (`--nested` skips the systemd user units). The log is in `/tmp/$USER/desktop.log`. Keep `-noreset`: without it Xephyr resets when its last client disconnects (right after `xrdb` and `setxkbmap` at startup), which wipes the X resources and the keymap. The real Xorg never does that, because LightDM keeps a connection open.
- Regenerate the rice wallpapers after changing a palette: `python3 tools/gen-wallpapers.py [id...]` (Pillow).
- Check every rice × desktop renders: source the libs with a throwaway `HOME` and call `rice_render <rootfs> <id> <desktop>` for each pair; no `{{TOKEN}}` may be left, and the rendered `bspwmrc`/`launch.sh` must pass `shellcheck -s sh`. awesome needs `etc/xdg/awesome/rc.lua` in the given rootfs.
- Lint: `shellcheck -x install.sh lib/*.sh bin/* guest/* share/xsessionrc desktops/*.conf rices/*/rice.conf`. Templates aren't shell until rendered (see above). shellcheck isn't on the host; get the static release binary into `/tmp/$USER/tools`.
- Use the environment: `junest` (shell), `junest -- <cmd>`, `junest -f -- pacman ...` (fakeroot)
- NVIDIA helper: `junest-nvidia status|path|fetch|keep`

## Architecture

- `bin/42desk` is the program. It sources `lib/*.sh` (`common`, then `cleanup`, `junest`, `guest`, `desktop`, `apps`, `folders`, `apps42`, `rice`, `profile`, and `cli` last, which holds the commands and `main`). The `lib` files only define functions and constants. `install.sh` just execs `bin/42desk install`.
  - `~/.local/bin/42desk` is a two-line launcher into the repo it was installed from (written by `install_wrappers`), because 42desk needs `lib/` and the catalogs. Public installs are planned to live in `~/.local/share/42desk` (cloned by a bootstrap script).
  - The menu runs each action in a subshell, so a `die` or "aborted" brings the menu back.
  - `CONFIG_VERSION` in the config; `migrate_config` brings older configs up to `CONFIG_SCHEMA`. Never give a script global the same name as a config key: `config_get` sources the config in a subshell that inherits the globals, so an unset key would read the global.
- The other `bin/` scripts get **copied** to `~/.local/bin` and run from there:
  - `junest`: the wrapper users actually call. It sources `~/.config/42-junest/config` (`JUNEST_HOME`, plus the `BINDS` array of host paths bound at the same place), then calls the pinned JuNest clone in `~/.local/share/junest`.
  - `junest-nvidia`: prepares the NVIDIA libraries (see below).
  - `junest-session`: starts the configured desktop on `$DISPLAY` (see the session flow below).
- `guest/` holds scripts copied into the rootfs's `/usr/local/bin`:
  - `prime-run`, `nvidia-smi`
  - `ft_lock`: asks the host to lock
  - `x-terminal-emulator`: `$TERMINAL` or xterm, used by the stock keybindings
- `desktops/<id>.conf` is the desktop catalog: `NAME`, `DESC`, `PACKAGES=()`, `START`, and `stock_config <rootfs>`. Adding a file adds a menu entry. `stock_config` copies the guest's default config into `~/.config` **only if missing**, plus the 42 patches (a Ctrl+Alt+L → `ft_lock` shortcut, guest lockers disabled). Switching desktops `pacman -Rns` the old desktop's packages; config folders are never deleted.
- `apps/NN-<category>.list` is the app catalog. Its header has `# name:` and `# role:`, then one app per line: `id | packages | description`. Ids are unique across files; menus follow the `NN` order.
  - Only official repos (no AUR).
  - Host apps are deliberately not offered; that was the user's choice. They can't run inside the guest anyway: `/usr` is replaced and the libraries don't match.
  - Installed apps are listed in `APPS` in the config.
  - Removing apps marks their packages `--asdeps`, then removes only those that `pacman -Qdttq` lists (`-tt`, because zathura and its plugin depend on each other only optionally). Chosen packages are re-marked `--asexplicit`.
- **Default apps.** A role (`terminal browser editor files video image pdf`) maps to MIME types in `ROLE_MIMES` (`lib/apps.sh`).
  - Defaults go to `~/.config/<desktop name, lowercase>-mimeapps.list`, never to `mimeapps.list`. The home is shared with GNOME, and this per-desktop file only applies when `XDG_CURRENT_DESKTOP` is ours.
  - `write_defaults` deletes only the files that carry its own header. It runs again after a desktop switch.
  - The terminal and browser binaries are stored as `APP_TERMINAL`/`APP_BROWSER`; `junest-session` exports them as `TERMINAL`/`BROWSER`.
- **Host folders** (`lib/folders.sh`) are stored in `BINDS=(...)` (`config_set_array`/`config_get_array`). The wrapper binds them with `--bind-try` at the next start.
  - With no `BINDS`, or an empty one, `/goinfre/$USER` and `/sgoinfre/$USER` start checked. The home's `~/goinfre` and `~/sgoinfre` symlinks point there, and they dangle without the bind.
  - `check_folder` refuses system paths, `/`, paths with spaces or `..`, anything already visible (`/tmp`, the home), and anything that contains or is inside the rootfs.
  - Missing folders (e.g. `/media` with no USB key plugged in) are kept; bwrap skips them.
- **42 apps** (`lib/apps42.sh`): the host's tools can't run in the guest, so they're rebuilt there. `FT_APPS` in the config lists them.
  - **norminette:** a venv in `/opt/42/norminette`, pinned to the host's `norminette -v` version, plus a `/usr/local/bin` link. `ft_apps_packages` keeps `python` out of the apps step's removals.
  - **header42:** 42Paris' `stdheader.vim`, plus `42header-user.vim` (`g:user42`/`g:mail42`, with the mail domain taken from the sgoinfre NFS server). Both go into `~/.vim/plugin` and `~/.config/nvim/plugin`, which the host's vim shares. Files carry a marker line; only marked files are replaced or removed.
  - examshell is deliberately not offered.
- **All questions use whiptail** (`ask_menu`, `ask_checklist`, `ask_radiolist`, `ask_yesno`, `ask_input` in `lib/common.sh`). There's no plain-text fallback.
  - whiptail draws on stderr, because stdout is captured by `$(...)`. `require_whiptail` therefore checks stdin and stderr, not stdout.
  - `--yes` never prompts. It keeps the items given as ON, or the current choice.
- `config_set` passes values to awk through `ENVIRON`: `awk -v` would eat the backslashes of the `%q` quoting and break sourcing the config.
- Host-side edits of guest files (`pacman.conf`, `makepkg.conf`) are done with sed directly on `$JUNEST_HOME/etc/...`. Package operations go through the wrapper (`guest` / `guest_root` in `lib/guest.sh`).
- **Rices** (`lib/rice.sh`): our own looks, official packages only. `rices/<id>/rice.conf` holds `NAME DESC DESKTOPS=() PACKAGES=()` (its font), a palette (`BG BG_ALT FG FG_DIM ACCENT ACCENT2 URGENT`, `COLORS=()` for terminal colors 0–15), `FONT FONT_SIZE FONT_SIZE_SMALL GTK_THEME ICONS GAP BORDER RADIUS BAR_POSITION`, and a generated `wallpaper.jpg`. Adding a folder adds a rice.
  - `rices/_templates/files` lists which template goes where, for which desktops, and whether it needs an app (terminal configs only for installed terminals). Templates use `{{KEY}}` tokens (`rice_vars`); a leftover token or a missing `{{MARK}}` line in the first 3 lines is an error. awesome's `rc.lua` is patched from the installed one instead (`_render_awesome_rc`).
  - Shared by every rice (`RICE_PACKAGES`): picom, polybar (i3, bspwm), rofi, dunst, feh, xsettingsd, xrdb, libnotify, Materia, Papirus, the nerd symbols font. Fonts of every rice stay installed while any rice is used (switching works offline); going back to stock removes all of them with `remove_orphans`.
  - **Ownership:** rendered files carry `RICE_MARK`. A user's file at the same path is moved to `~/.config/42-junest/rice-backup/` first (a second one gets a dated name, never overwritten) and comes back with the stock look. `$RICE_STATE/files` lists what's placed (files no longer rendered are un-placed on each render); `$RICE_STATE/dirs` lists the folders the rice created, deleted with stock only if empty.
  - GTK settings go through xsettingsd and X resources through `xrdb -merge` of `~/.config/42-junest/rice/Xresources`, never `~/.Xresources` or `gtk-3.0/settings.ini`: GNOME shares the home. XFCE instead gets xfconf properties at session start; `rice-xfce-reset` (set whenever a rice is rendered for XFCE) makes the next stock XFCE session reset them.
  - The rice step runs after desktop; `setup_desktop` and `setup_apps` call `rice_refresh` (other WM files, new terminals, or drop the rice when the desktop has none).
- **Profiles** (`lib/profile.sh`): `KEY=value` files with a `# 42desk profile` first line. They are shared between students, so they're **parsed, never sourced**: only `PROFILE_KEYS`, values limited to `[A-Za-z0-9 ._@/+:,-]`. The login is written as `@USER@` (whole path components, the 42 header login and mail prefix).
  - A missing key keeps that step's current choice; an empty one means "none". Unknown desktop → none, unknown rice → stock, unknown app or 42 app ids are dropped with a warning.
  - Applying one (`profile_presets`) only sets the steps' `--yes` presets (`DESKTOP_CHOICE`, `RICE_CHOICE`, `FOLDERS_PRESET`, `APPS_PRESET`, `FT_PRESET`) and writes `DEFAULT_*`/`HEADER42_*` to the config, which the steps then take as current values. Presets are checked with `${VAR+x}`, so an empty preset is honored.
  - `run_step` auto-saves the setup to `~/.config/42-junest/profile` after every step; `install` offers it (and the bundled ones) before the rootfs question.
  - The 42 header remembers its login and mail in `HEADER42_USER`/`HEADER42_MAIL`.
- `remove_orphans` (`lib/guest.sh`) and `kept_packages` (`lib/apps.sh`) are the only way packages get removed by the apps and rice steps: candidates minus everything something configured still needs, marked `--asdeps`, then only pacman's `-Qdttq` orphans go.
- `guest`/`guest_root` run directly (with the guest's fakeroot `sudo`) when `JUNEST_ENV` is set, so `42desk` works from a terminal inside the desktop; `install` still refuses to run there.
- New steps plug in the same way: a new `lib/*.sh` file (sourced in `bin/42desk`), an entry in `STEPS` and `run_step` (`lib/cli.sh`), and persistent choices in the config file. `write_config` keeps `BINDS` across reinstalls.

## Invariants

- **Nothing loose in `/tmp`**: everything goes under `/tmp/$USER` (mode 700; refuse to use it if another user owns it). The wrapper recreates the tree at every launch, because `/tmp` is wiped at reboot. Large or temporary data lives there, never in the quota-limited home:
  - pacman `CacheDir`
  - makepkg `BUILDDIR`, `SRCDEST`, `PKGDEST`
  - `XDG_CACHE_HOME` for guest processes
  - the JuNest image download (`JUNEST_TEMPDIR`)
  - the NVIDIA `.run` download
- **JuNest `ns` mode only** (bwrap). The wrapper's binds are passed as one `-b` string that JuNest word-splits, so bound paths can't contain spaces. JuNest itself always binds `/tmp`, `$HOME`, `/dev`, `/sys`, `/proc` and `/run/user/$UID`.
- **NVIDIA comes from the host driver version, not Arch packages.**
  - `junest-nvidia fetch` downloads the `.run` that matches `/sys/module/nvidia/version` and keeps only the userspace vendor libs. It strips the bundled glvnd and EGL-platform libs, which would shadow Arch's newer ones.
  - It then writes the Vulkan ICD, EGL vendor and GBM files and stores the result in `/goinfre/$USER/junest-nvidia/<ver>`. `keep` copies it to `~/.local/share/junest-nvidia`.
  - The wrapper ro-binds that dir and exports `LD_LIBRARY_PATH`, `VK_ADD_DRIVER_FILES`, `__EGL_VENDOR_LIBRARY_DIRS`, `GBM_BACKENDS_PATH` and `WLR_RENDERER=vulkan`.
  - The machines are hybrid Intel + NVIDIA: Mesa is the default, and `prime-run` offloads to NVIDIA.
- **No AUR helper.** The yay-git shipped in the JuNest image links to a fixed `libalpm` soname and breaks after the first pacman upgrade, so `remove_yay` uninstalls it before the base packages go in. If an app needs the AUR, build it with `git clone` + `makepkg` (build dirs are already in `/tmp/$USER/makepkg`), then `pacman -U`.
- **Session flow.** `~/.xsessionrc` holds a marked block (`# >>> 42-junest >>>`) that sources `~/.local/share/42-junest/xsessionrc` (from `share/xsessionrc`, POSIX sh). The display manager (LightDM on the 42 computers) sources it from `/etc/X11/Xsession.d` before gnome-session starts.
  - It runs `junest-session`. A status of 0 after at least 10 s calls `exit`, which logs out. Anything else returns, so GNOME starts as the fallback.
  - Escape hatch: `touch ~/.config/42-junest/desktop-disabled`.
  - `junest-session` does the following, in order:
    1. Fetches the NVIDIA libs if they're missing, with a zenity window.
    2. Cleans the GNOME variables already set for the session (`XDG_CURRENT_DESKTOP`, `SESSION_MANAGER`, `XDG_DATA_DIRS`, ...).
    3. Starts the units in `/etc/systemd/user/graphical-session.target.wants` (the 42 `nats-user-agent`). Only gnome-session would start them otherwise.
    4. Applies the GNOME keyboard layouts with `setxkbmap`.
    5. Runs `junest -- dbus-run-session -- 42desk-start $DESKTOP_START`. `42desk-start` (guest) writes `$XDG_RUNTIME_DIR/42-junest/session.env` (DISPLAY and the session bus, removed by `junest-session` at exit), runs `42desk-rice-apply start` (X resources, wallpaper, dunst, xsettingsd, picom with glx or xrender, or the XFCE properties), runs the desktop, then `42desk-rice-apply stop-daemons` (also polybar and sxhkd, which would keep their key grabs).
  - Live rice changes: `rice_reload` runs `42desk-rice-apply reload` directly inside the session, or through `junest` with `session.env` from the host; it restarts the WM in place (`i3-msg restart`, `bspc wm -r`, SIGHUP for awesome).
- **Locking goes through the host.** 42's `ft_lock` is a host binary, and lockers running in the guest can't check the 42 password, so never install i3lock or similar.
  - `junest-session` runs a FIFO bridge at `$XDG_RUNTIME_DIR/42-junest/host.fifo`. The guest `ft_lock` writes `lock`; the host debounces it and runs `/usr/local/bin/ft_lock`.
  - Don't skip based on `pgrep ft_lock`: ft_lock leaves a `[ft_ld]` daemon with that name running.
  - Idle locking is done by 42's root `idle-watch.sh` (xprintidle on `:0`) and works with any X11 desktop.
  - When testing, never `pkill ft_lock`: kill only the PIDs you started, or close the Xephyr display.
- Cleanup deletes a directory only if `is_rootfs` says it is a pacman rootfs. Unknown top-level files in it are moved to a `junest-backup-<date>` folder first.

## Host environment

- Ubuntu 22.04 with GNOME, no root. Unprivileged user namespaces are enabled.
- Home is a ~28 GB quota. `/goinfre/$USER` is large but specific to each computer. `/sgoinfre` is shared NFS (often full).
