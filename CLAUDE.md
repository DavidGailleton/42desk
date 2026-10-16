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

Done so far: the base install and step 1 (the desktop choice: i3, bspwm, awesome or XFCE, all native X11). Hyprland and other Wayland compositors can't work here: GDM's Xorg owns the GPU, and Hyprland has no X11 backend.

## Commands

- Install (fresh: wipes any previous setup after a confirmation): `./install.sh [--rootfs PATH] [--desktop ID|none] [--yes]`
- Re-run one step on the existing install: `./install.sh --step desktop [--desktop i3|bspwm|awesome|xfce|none]`
- Try the configured desktop without logging out: `Xephyr :5 -screen 1600x900 & DISPLAY=:5 junest-session --nested` (`--nested` skips the systemd user units). The log is in `/tmp/$USER/desktop.log`.
- Lint: `shellcheck -x install.sh lib/*.sh bin/* guest/* share/xsessionrc desktops/*.conf`. shellcheck isn't on the host; get the static release binary into `/tmp/$USER/tools`.
- Use the environment: `junest` (shell), `junest -- <cmd>`, `junest -f -- pacman ...` (fakeroot)
- NVIDIA helper: `junest-nvidia status|path|fetch|keep`

## Architecture

- `install.sh` sources `lib/*.sh` (`common`, then `cleanup`, `junest`, `guest`, `desktop`) and runs the steps in order. The `lib` files only define functions and constants.
- `bin/` holds scripts that get **installed** to `~/.local/bin`, not run from the repo:
  - `junest`: the wrapper users actually call. It sources `~/.config/42-junest/config` (`JUNEST_HOME`, plus the `BINDS` array of host paths bound at the same place), then calls the pinned JuNest clone in `~/.local/share/junest`.
  - `junest-nvidia`: prepares the NVIDIA libraries (see below).
  - `junest-session`: starts the configured desktop on `$DISPLAY` (see the session flow below).
- `guest/` holds scripts copied into the rootfs's `/usr/local/bin`:
  - `prime-run`, `nvidia-smi`
  - `ft_lock`: asks the host to lock
  - `x-terminal-emulator`: `$TERMINAL` or xterm, used by the stock keybindings
- `desktops/<id>.conf` is the desktop catalog: `NAME`, `DESC`, `PACKAGES=()`, `START`, and `stock_config <rootfs>`. Adding a file adds a menu entry. `stock_config` copies the guest's default config into `~/.config` **only if missing**, plus the 42 patches (a Ctrl+Alt+L → `ft_lock` shortcut, guest lockers disabled). Switching desktops `pacman -Rns` the old desktop's packages; config folders are never deleted.
- Host-side edits of guest files (`pacman.conf`, `makepkg.conf`) are done with sed directly on `$JUNEST_HOME/etc/...`. Package operations go through the wrapper (`guest` / `guest_root` in `lib/guest.sh`).
- Later steps (rice, passthrough folders, apps) are meant to plug in the same way: new `lib/*.sh` files, with persistent choices kept in the config file. `write_config` keeps `BINDS` across reinstalls.

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
- **Session flow.** `~/.xsessionrc` holds a marked block (`# >>> 42-junest >>>`) that sources `~/.local/share/42-junest/xsessionrc` (from `share/xsessionrc`, POSIX sh). GDM sources it before gnome-session starts.
  - It runs `junest-session`. A status of 0 after at least 10 s calls `exit`, which logs out. Anything else returns, so GNOME starts as the fallback.
  - Escape hatch: `touch ~/.config/42-junest/desktop-disabled`.
  - `junest-session` does the following, in order:
    1. Fetches the NVIDIA libs if they're missing, with a zenity window.
    2. Cleans the GNOME variables GDM has already set (`XDG_CURRENT_DESKTOP`, `SESSION_MANAGER`, `XDG_DATA_DIRS`, ...).
    3. Starts the units in `/etc/systemd/user/graphical-session.target.wants` (the 42 `nats-user-agent`). Only gnome-session would start them otherwise.
    4. Applies the GNOME keyboard layouts with `setxkbmap`.
    5. Runs `junest -- dbus-run-session -- $DESKTOP_START`.
- **Locking goes through the host.** 42's `ft_lock` is a host binary, and lockers running in the guest can't check the 42 password, so never install i3lock or similar.
  - `junest-session` runs a FIFO bridge at `$XDG_RUNTIME_DIR/42-junest/host.fifo`. The guest `ft_lock` writes `lock`; the host debounces it and runs `/usr/local/bin/ft_lock`.
  - Don't skip based on `pgrep ft_lock`: ft_lock leaves a `[ft_ld]` daemon with that name running.
  - Idle locking is done by 42's root `idle-watch.sh` (xprintidle on `:0`) and works with any X11 desktop.
  - When testing, never `pkill ft_lock`: kill only the PIDs you started, or close the Xephyr display.
- Cleanup deletes a directory only if `is_rootfs` says it is a pacman rootfs. Unknown top-level files in it are moved to a `junest-backup-<date>` folder first.

## Host environment

- Ubuntu 22.04 with GNOME, no root. Unprivileged user namespaces are enabled.
- Home is a ~28 GB quota. `/goinfre/$USER` is large but specific to each computer. `/sgoinfre` is shared NFS (often full).
