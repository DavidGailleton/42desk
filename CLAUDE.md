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

Only the base install exists so far.

## Commands

- Install (fresh: wipes any previous setup after a confirmation): `./install.sh [--rootfs PATH] [--yes]`
- Lint: `shellcheck -x install.sh lib/*.sh bin/* guest/*`. shellcheck isn't on the host; get the static release binary into `/tmp/$USER/tools`.
- Use the environment: `junest` (shell), `junest -- <cmd>`, `junest -f -- pacman ...` (fakeroot)
- NVIDIA helper: `junest-nvidia status|path|fetch|keep`

## Architecture

- `install.sh` sources `lib/*.sh` (`common`, then `cleanup`, `junest`, `guest`) and runs the steps in order. The `lib` files only define functions and constants.
- `bin/` holds scripts that get **installed** to `~/.local/bin`, not run from the repo:
  - `junest`: the wrapper users actually call. It sources `~/.config/42-junest/config` (`JUNEST_HOME`, plus the `BINDS` array of host paths bound at the same place), then calls the pinned JuNest clone in `~/.local/share/junest`.
  - `junest-nvidia`: prepares the NVIDIA libraries (see below).
- `guest/` holds scripts copied into the rootfs's `/usr/local/bin` (`prime-run`, `nvidia-smi`).
- Host-side edits of guest files (`pacman.conf`, `makepkg.conf`) are done with sed directly on `$JUNEST_HOME/etc/...`. Package operations go through the wrapper (`guest` / `guest_root` in `lib/guest.sh`).
- Later steps (the desktop environment and app choices) are meant to plug in the same way: new `lib/*.sh` files, with persistent choices kept in the config file. `write_config` keeps `BINDS` across reinstalls.

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
- Cleanup deletes a directory only if `is_rootfs` says it is a pacman rootfs. Unknown top-level files in it are moved to a `junest-backup-<date>` folder first.

## Host environment

- Ubuntu 22.04 with GNOME, no root. Unprivileged user namespaces are enabled.
- Home is a ~28 GB quota. `/goinfre/$USER` is large but specific to each computer. `/sgoinfre` is shared NFS (often full).
