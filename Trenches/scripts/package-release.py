import argparse
import hashlib
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import zipfile

project = pathlib.Path(__file__).resolve().parents[1]
repository = project.parent
parser = argparse.ArgumentParser(description="Prepare public release files from the share IPA")
parser.add_argument("--ipa", type=pathlib.Path, default=project / "xtool" / "Trenches-share.ipa")
args = parser.parse_args()
source_info = plistlib.loads((project / "Info.plist").read_bytes())
version = source_info["CFBundleShortVersionString"]
if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", version):
    parser.error("Expected a semantic version in Info.plist")
notes = repository / "docs" / "releases" / f"v{version}.md"
if not notes.is_file():
    parser.error(f"Missing release notes: {notes}")
if not args.ipa.is_file():
    parser.error("Share IPA not found. Run build.sh -c release first")

# Fail before copying anything if a personal signing profile or stale build is supplied.
subprocess.run([sys.executable, str(project / "scripts" / "inspect-ipa.py"), str(args.ipa), "--unsigned"], check=True)
with zipfile.ZipFile(args.ipa) as archive:
    info_path = next(name for name in archive.namelist() if name.count("/") == 2 and name.endswith(".app/Info.plist"))
    info = plistlib.loads(archive.read(info_path))
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        if info[key] != source_info[key]:
            parser.error(f"IPA {key} differs from source; rebuild before packaging")
    if info.get("TrenchesRunVerification"):
        parser.error("Diagnostic IPA cannot be published as the normal camera")

files = [repository / name for name in ("README.md", "LICENSE", "CHANGELOG.md", ".gitignore", ".gitattributes")]
files += [project / name for name in ("Package.swift", "Info.plist", "xtool.yml", ".gitignore")]
for directory in (repository / "docs", repository / ".github", project / "Sources", project / "Resources", project / "scripts", project / "Tests"):
    files.extend(path for path in directory.rglob("*") if path.is_file() and "__pycache__" not in path.parts)
for path in files:
    if path.is_symlink() or not path.resolve().is_relative_to(repository):
        parser.error(f"Unexpected source path: {path}")
    if path.suffix.lower() in {".ipa", ".mobileprovision", ".p12", ".p8", ".pem", ".key", ".cer", ".log", ".pyc"} or path.name.startswith(".env"):
        parser.error(f"Unexpected private or generated file in sources: {path}")

output = repository / "dist" / f"v{version}"
output.mkdir(parents=True, exist_ok=True)
ipa_output = output / f"trenches-{version}.ipa"
shutil.copyfile(args.ipa, ipa_output)
source_output = output / f"trenches-{version}-source.zip"
with zipfile.ZipFile(source_output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in sorted(set(files)):
        relative = path.relative_to(repository).as_posix()
        entry = zipfile.ZipInfo(relative, date_time=(2026, 1, 1, 0, 0, 0))
        entry.create_system = 3
        entry.external_attr = 0o100644 << 16
        entry.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(entry, path.read_bytes())
notes_output = output / "release-notes.md"
shutil.copyfile(notes, notes_output)
artifacts = (ipa_output, source_output, notes_output)
checksums = "".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in artifacts)
with (output / "SHA256SUMS.txt").open("w", encoding="utf-8", newline="\n") as stream:
    stream.write(checksums)
print(f"\nRelease ready: {output}")
for path in artifacts:
    print(f"  {path.name} ({path.stat().st_size:,} bytes)")
