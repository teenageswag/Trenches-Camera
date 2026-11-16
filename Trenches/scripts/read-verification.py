import argparse
import ctypes as c
import ctypes.util
import pathlib
import plistlib
import zipfile

parser = argparse.ArgumentParser(description="Read only the app's technical text report over USB")
parser.add_argument("output", nargs="?", type=pathlib.Path)
parser.add_argument("--camera", action="store_true", help="Read counters from the last camera recording")
parser.add_argument("--datamosh", action="store_true", help="Read technical Datamosh preview timestamps, without video content")
parser.add_argument("--bundle-id", help="Override the Bundle ID from the local signed IPA")
args = parser.parse_args()
bundle_id = args.bundle_id
if not bundle_id:
    ipa = pathlib.Path(__file__).resolve().parents[1] / "xtool" / "Trenches.ipa"
    if not ipa.is_file():
        parser.error("Build a signed IPA first or provide --bundle-id")
    with zipfile.ZipFile(ipa) as archive:
        info_path = next(name for name in archive.namelist() if name.count("/") == 2 and name.endswith(".app/Info.plist"))
        bundle_id = plistlib.loads(archive.read(info_path))["CFBundleIdentifier"]

lib = c.CDLL(ctypes.util.find_library("imobiledevice-1.0"))
pointer = c.c_void_p


def bind(name, arguments):
    function = getattr(lib, name)
    function.argtypes = arguments
    function.restype = c.c_int
    return function


def check(code, operation):
    if code:
        raise RuntimeError(f"{operation}: error {code}")


device = pointer()
house = pointer()
afc = pointer()
handle = c.c_uint64()
report_name = "datamosh-preview.txt" if args.datamosh else ("camera-performance.txt" if args.camera else "verification.txt")
try:
    check(bind("idevice_new", [c.POINTER(pointer), c.c_char_p])(c.byref(device), None), "Connect device")
    check(bind("house_arrest_client_start_service", [pointer, c.POINTER(pointer), c.c_char_p])(device, c.byref(house), b"trenches-diagnostics"), "Open app service")
    check(bind("house_arrest_send_command", [pointer, c.c_char_p, c.c_char_p])(house, b"VendDocuments", bundle_id.encode()), "Request app documents")
    result = pointer()
    check(bind("house_arrest_get_result", [pointer, c.POINTER(pointer)])(house, c.byref(result)), "Read app service response")
    if result:
        plist = c.CDLL(ctypes.util.find_library("plist-2.0"))
        plist.plist_free.argtypes = [pointer]
        plist.plist_free(result)
    check(bind("afc_client_new_from_house_arrest_client", [pointer, c.POINTER(pointer)])(house, c.byref(afc)), "Open app file access")
    open_file = bind("afc_file_open", [pointer, c.c_char_p, c.c_uint64, c.POINTER(c.c_uint64)])
    code = open_file(afc, ("Documents/" + report_name).encode(), 1, c.byref(handle))
    if code == 8:
        code = open_file(afc, report_name.encode(), 1, c.byref(handle))
    check(code, "Open verification report (open the diagnostic app first)")
    read = bind("afc_file_read", [pointer, c.c_uint64, pointer, c.c_uint32, c.POINTER(c.c_uint32)])
    chunks = []
    while True:
        data = c.create_string_buffer(4096)
        count = c.c_uint32()
        check(read(afc, handle, data, len(data), c.byref(count)), "Read verification report")
        if not count.value:
            break
        chunks.append(data.raw[:count.value])
    report = b"".join(chunks).decode("utf-8")
    print(report)
    if args.output:
        args.output.write_text(report, encoding="utf-8")
finally:
    if handle.value and afc:
        bind("afc_file_close", [pointer, c.c_uint64])(afc, handle)
    if afc:
        bind("afc_client_free", [pointer])(afc)
    if house:
        bind("house_arrest_client_free", [pointer])(house)
    if device:
        bind("idevice_free", [pointer])(device)
