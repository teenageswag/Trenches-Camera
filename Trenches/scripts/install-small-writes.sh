#!/usr/bin/env bash
set -euo pipefail
if [[ -r "$HOME/.local/share/swiftly/env.sh" ]]; then source "$HOME/.local/share/swiftly/env.sh"; fi
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
helper_dir="${XDG_CACHE_HOME:-$HOME/.cache}/trenches-install"
mkdir -p "$helper_dir"
clang -O2 -shared -fPIC "$project_dir/scripts/afc-small-writes.c" -ldl -o "$helper_dir/afc-small-writes.so"
LD_PRELOAD="$helper_dir/afc-small-writes.so" ideviceinstaller install "$project_dir/xtool/Trenches.ipa"
