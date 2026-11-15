import argparse
import hashlib
import pathlib
import plistlib
import re
import subprocess
import struct
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument("ipa", type=pathlib.Path)
parser.add_argument("--unsigned", action="store_true", help="Validate the share build without a provisioning profile")
args = parser.parse_args()
path = args.ipa
config = pathlib.Path(__file__).resolve().parents[1] / "xtool.yml"
bundle_id = re.search(r"(?m)^bundleID:\s*([^\s#]+)", config.read_text(encoding="utf-8")).group(1).strip("\"'")


def version_string(value):
    return f"{value >> 16}.{(value >> 8) & 255}.{value & 255}"


def deployment_version(binary):
    assert binary[:4] == bytes.fromhex("cffaedfe"), "Not an arm64 Mach-O"
    header = struct.unpack_from("<8I", binary)
    assert header[1] == 0x0100000C, "Not arm64"
    offset = 32
    for _ in range(header[4]):
        command, size = struct.unpack_from("<II", binary, offset)
        assert size >= 8 and offset + size <= len(binary), "Invalid load command"
        if command == 0x32:
            platform, minimum = struct.unpack_from("<II", binary, offset + 8)
            assert platform == 2, "Not an iOS device binary"
            return minimum
        if command == 0x25:
            return struct.unpack_from("<I", binary, offset + 8)[0]
        offset += size
    raise AssertionError("Missing binary deployment target")


with zipfile.ZipFile(path) as archive:
    names = archive.namelist()
    info_path = next(name for name in names if name.count("/") == 2 and name.endswith(".app/Info.plist"))
    root = info_path.removesuffix("Info.plist")
    info = plistlib.loads(archive.read(info_path))
    binary_minimum = deployment_version(archive.read(root + info["CFBundleExecutable"]))
    assert binary_minimum <= 0x00120000, "Binary requires newer than iOS 18.0"
    assert tuple(map(int, info["MinimumOSVersion"].split("."))) <= (18, 0), "Info.plist requires newer than iOS 18.0"
    assert any(name.endswith("Shaders/Effects.metal") for name in names), "Missing shader resource"
    print("Bundle:", info["CFBundleIdentifier"])
    print("Version:", info["CFBundleShortVersionString"])
    print("Minimum iOS (Info.plist):", info["MinimumOSVersion"])
    print("Minimum iOS (Mach-O):", version_string(binary_minimum))
    print("Size:", path.stat().st_size, "bytes")
    if args.unsigned:
        assert root + "embedded.mobileprovision" not in names, "Share build contains a device provisioning profile"
        assert info["CFBundleIdentifier"] == bundle_id, "Share build does not match the configured Bundle ID"
        print("Signing: share build, requires the recipient's own signing")
    else:
        assert any("_CodeSignature/CodeResources" in name for name in names), "Missing signature"
        profile = archive.read(root + "embedded.mobileprovision")
        decoded = subprocess.run(["openssl", "cms", "-verify", "-inform", "DER", "-noverify"], input=profile, capture_output=True, check=True).stdout
        profile = plistlib.loads(decoded)
        print("Profile expires (UTC):", profile["ExpirationDate"].isoformat())
        print("Provisioned devices:", len(profile.get("ProvisionedDevices", [])))
    print("SHA256:", hashlib.sha256(path.read_bytes()).hexdigest())
    print("PASS: arm64, iOS 18 deployment target, shaders, signing state")
