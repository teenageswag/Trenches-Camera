#!/usr/bin/env bash
set -euo pipefail
if [[ -r "$HOME/.local/share/swiftly/env.sh" ]]; then source "$HOME/.local/share/swiftly/env.sh"; fi
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${XDG_CACHE_HOME:-$HOME/.cache}/trenches-build"
mkdir -p "$build_dir"
# xtool's Foundation bundle copier cannot preserve NTFS directory metadata.
# Keep source on Windows, and compile/package on WSL's ext4 filesystem.
rsync -rlt --delete --exclude .build --exclude .bsp --exclude xtool --exclude diagnostics --exclude __pycache__ --exclude '*.log' "$project_dir/" "$build_dir/"
cd "$build_dir"
if [[ "${TRENCHES_VERIFY:-0}" == 1 ]]; then
    python3 - <<'PY'
import plistlib
from pathlib import Path
path = Path('Info.plist')
info = plistlib.loads(path.read_bytes())
info['TrenchesRunVerification'] = True
path.write_bytes(plistlib.dumps(info))
PY
fi
xtool dev build --ipa "$@"
mkdir -p "$project_dir/xtool"
artifact_name=Trenches-share.ipa
for argument in "$@"; do
    if [[ "$argument" == --sign || "$argument" == -s ]]; then artifact_name=Trenches.ipa; fi
done
cp "$build_dir/xtool/Trenches.ipa" "$project_dir/xtool/$artifact_name"
printf '\nArtifact: %s/xtool/%s\n' "$project_dir" "$artifact_name"
