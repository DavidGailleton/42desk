#!/usr/bin/env bash
# Fresh install of a custom JuNest desktop for 42 computers: same as
# `bin/42desk install`. Afterwards, run `42desk` to change the setup.
#
# Usage: ./install.sh [--rootfs PATH] [--desktop ID|none] [--yes]
#        ./install.sh --step folders|desktop|apps|42apps   (= 42desk configure STEP)
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for arg in "$@"; do
    [[ $arg == --step ]] && exec "$REPO_DIR/bin/42desk" "$@"
done
exec "$REPO_DIR/bin/42desk" install "$@"
