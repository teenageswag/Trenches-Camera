#!/usr/bin/env bash
set -euo pipefail
if [[ -r "$HOME/.local/share/swiftly/env.sh" ]]; then source "$HOME/.local/share/swiftly/env.sh"; fi
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="${XDG_CACHE_HOME:-$HOME/.cache}/trenches-tests"
mkdir -p "$test_dir"
swiftc "$project_dir/Sources/Trenches/EffectSettings.swift" "$project_dir/Tests/SettingsChecks.swift" -o "$test_dir/settings-checks"
"$test_dir/settings-checks"
