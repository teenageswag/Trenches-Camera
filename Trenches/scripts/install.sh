#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ipa="$project_dir/xtool/Trenches.ipa"
if [[ ! -f "$ipa" ]]; then
    printf 'IPA not found. Run: bash scripts/build.sh --sign\n' >&2
    exit 1
fi
if [[ "$(uname -s)" == Linux ]] && command -v ideviceinstaller >/dev/null 2>&1; then
    bash "$project_dir/scripts/install-small-writes.sh"
else
    xtool install --usb "$ipa"
fi
bundle_id="$(python3 - "$ipa" <<'PY'
import plistlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    path = next(name for name in archive.namelist() if name.count('/') == 2 and name.endswith('.app/Info.plist'))
    print(plistlib.loads(archive.read(path))['CFBundleIdentifier'])
PY
)"
printf '\nInstalled: %s\nOpen trenches on your iPhone.\n' "$bundle_id"
