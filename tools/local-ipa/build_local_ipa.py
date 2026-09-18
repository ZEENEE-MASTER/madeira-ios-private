#!/usr/bin/env python3
"""Madeira IPA built on Windows — no macOS, no paid CI.

Same approach as the CP2077 port (acshadows-ios/tools/build_ipa_windows.py):
Windows LLVM clang + a local iPhoneOS SDK for native code, Python for packaging.

It cannot recompile the Swift app (no Swift/Xcode here), so it starts from the
last CI-built IPA and adds what can be built on this PC:

  Frameworks/MadeiraPad.dylib   controllers -> XInput block, rumble, launch
                                defaults, Documents/madeira-launch.txt override
                                (injected with an LC_LOAD_DYLIB load command)
  <dll dirs>/xinput*.dll        Madeira XInput (x86-64, freestanding clang)
  Info.plist                    games category + Game Mode + controller keys

Usage: python build_local_ipa.py [base.ipa] [out.ipa]
"""
import pathlib, plistlib, shutil, struct, subprocess, sys, zipfile

HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE / "src"
LLVM = pathlib.Path(r"C:\Program Files\LLVM\bin")
CLANG = str(LLVM / "clang.exe")
LLD_LINK = str(LLVM / "lld-link.exe")
DLLTOOL = str(LLVM / "llvm-dlltool.exe")
SDK = r"C:\Users\NFO\Documents\ios-sdks\iPhoneOS16.5.sdk"
IPA_DIR = pathlib.Path(r"F:\CLAUDE SESSION\Madeira-IPA")

DYLIB_NAME = "MadeiraPad.dylib"
DYLIB_LOAD = "@executable_path/Frameworks/" + DYLIB_NAME
XINPUT_NAMES = ["xinput1_1", "xinput1_2", "xinput1_3", "xinput1_4", "xinput9_1_0"]


def run(cmd, what):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"{what} failed:\n{' '.join(cmd)}\n{r.stdout[-2000:]}\n{r.stderr[-4000:]}")
    return r


def build_dylib(out):
    run([CLANG, "--target=arm64-apple-ios16.0", "-isysroot", SDK, "-arch", "arm64",
         "-miphoneos-version-min=16.0", "-O2", "-dynamiclib", "-fobjc-arc", "-nostdlib",
         "-Wl,-undefined,dynamic_lookup", "-x", "objective-c",
         "-framework", "Foundation", "-framework", "GameController", "-framework", "CoreHaptics",
         "-Wl,-install_name," + DYLIB_LOAD,
         "-o", str(out), str(SRC / "MadeiraPad.m")], "MadeiraPad.dylib")
    print(f"  built {out.name} ({out.stat().st_size} bytes)")


def build_xinput(work):
    kdef = work / "kernel32.def"
    kdef.write_text("LIBRARY kernel32.dll\nEXPORTS\n    GetEnvironmentVariableA\n    DisableThreadLibraryCalls\n")
    klib = work / "kernel32.lib"
    run([DLLTOOL, "-m", "i386:x86-64", "-d", str(kdef), "-l", str(klib)], "kernel32 import lib")
    obj = work / "xinput.obj"
    run([CLANG, "--target=x86_64-pc-windows-msvc", "-O2", "-ffreestanding", "-fno-stack-protector",
         "-fno-builtin", "-DMADEIRA_FREESTANDING", "-Wall", "-Wno-unused-parameter",
         "-c", str(SRC / "xinput.c"), "-o", str(obj)], "xinput compile")
    out = []
    for name in XINPUT_NAMES:
        d = work / f"{name}.def"
        d.write_text(f"""LIBRARY {name}.dll
EXPORTS
    XInputGetState @2
    XInputSetState @3
    XInputGetCapabilities @4
    XInputEnable @5
    XInputGetDSoundAudioDeviceGuids @6
    XInputGetBatteryInformation @7
    XInputGetKeystroke @8
    XInputGetAudioDeviceIds @10
    XInputGetStateEx @100 NONAME
    XInputWaitForGuideButton @101 NONAME
    XInputCancelGuideButtonWait @102 NONAME
    XInputPowerOffController @103 NONAME
    XInputGetBaseBusInformation @104 NONAME
    XInputGetCapabilitiesEx @108 NONAME
""")
        dll = work / f"{name}.dll"
        run([LLD_LINK, "/dll", "/nodefaultlib", "/entry:DllMain", "/machine:x64", "/subsystem:windows",
             f"/def:{d}", f"/out:{dll}", str(obj), str(klib)], f"link {name}")
        out.append(dll)
    print(f"  built {len(out)} XInput DLLs ({out[0].stat().st_size} bytes each)")
    return out


def insert_load_dylib(path, dylib):
    data = bytearray(path.read_bytes())
    magic, cpu, sub, ftype, ncmds, sizeofcmds, flags, _ = struct.unpack_from("<IiiIIIII", data, 0)
    assert magic == 0xFEEDFACF, "not a 64-bit Mach-O"
    off, first_file_off = 32, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd in (0xC, 0x80000018):
            nameoff = struct.unpack_from("<I", data, off + 8)[0]
            if data[off + nameoff:off + size].split(b"\0")[0].decode() == dylib:
                print("  LC_LOAD_DYLIB already present")
                return
        if cmd == 0x1D:
            sys.exit("binary is code-signed; strip the signature first")
        if cmd == 0x19:
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            for s in range(nsects):
                so = off + 72 + s * 80
                fo = struct.unpack_from("<I", data, so + 48)[0]
                if fo and (first_file_off is None or fo < first_file_off):
                    first_file_off = fo
        off += size
    name = dylib.encode() + b"\0"
    cmdsize = (24 + len(name) + 7) & ~7
    end = 32 + sizeofcmds
    if end + cmdsize > first_file_off or any(data[end:end + cmdsize]):
        sys.exit(f"no room for a load command ({first_file_off - end} bytes free)")
    lc = struct.pack("<IIIIII", 0xC, cmdsize, 24, 2, 0x10000, 0x10000) + name
    data[end:end + cmdsize] = lc.ljust(cmdsize, b"\0")
    struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + cmdsize)
    path.write_bytes(bytes(data))
    print(f"  LC_LOAD_DYLIB {dylib} inserted ({first_file_off - end - cmdsize} header bytes left)")


def main():
    if len(sys.argv) > 1:
        base = pathlib.Path(sys.argv[1])
    else:
        # Newest IPA in the folder: re-injecting into our own output is fine
        # (the load command is added only once) and survives cleanups of the
        # original CI build.
        found = sorted(IPA_DIR.glob("Madeira-*.ipa"), key=lambda p: p.stat().st_mtime)
        if not found:
            sys.exit(f"no base IPA in {IPA_DIR}")
        base = found[-1]
    # Next number after the highest one present, so a deleted build's name is
    # never reused for a newer one.
    nums = [int(p.stem.rsplit("-", 1)[1]) for p in IPA_DIR.glob("Madeira-local-*.ipa")
            if p.stem.rsplit("-", 1)[1].isdigit()]
    n = max(nums, default=0) + 1
    out = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else IPA_DIR / f"Madeira-local-{n}.ipa"
    work = HERE / "work"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir()

    print(f"==> base {base.name}")
    with zipfile.ZipFile(base) as z:
        z.extractall(work / "ipa")
    app = work / "ipa" / "Payload" / "Madeira.app"
    assert (app / "Madeira").exists(), "base IPA has no Madeira.app/Madeira"

    print("==> native pieces (clang + iPhoneOS SDK)")
    (app / "Frameworks").mkdir(exist_ok=True)
    build_dylib(app / "Frameworks" / DYLIB_NAME)
    insert_load_dylib(app / "Madeira", DYLIB_LOAD)

    print("==> XInput DLLs (clang x86-64, freestanding)")
    dlls = build_xinput(work)
    for d in ("arm64ec-windows", "x86_64-vcruntime"):
        if (app / d).is_dir():
            for dll in dlls:
                shutil.copy2(dll, app / d / dll.name)
            print(f"  {d}: xinput DLLs replaced")

    print("==> Info.plist")
    with open(app / "Info.plist", "rb") as f:
        info = plistlib.load(f)
    info.update({
        "LSApplicationCategoryType": "public.app-category.games",
        "GCSupportsGameMode": True,
        "GCSupportsControllerUserInteraction": True,
        "GCSupportedGameControllers": [{"ProfileName": "ExtendedGamepad"}],
    })
    info["CFBundleVersion"] = str(int(str(info.get("CFBundleVersion", "1")).split(".")[0]) + n)
    with open(app / "Info.plist", "wb") as f:
        plistlib.dump(info, f)

    print("==> zip")
    out.unlink(missing_ok=True)
    root = work / "ipa"
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for p in sorted(root.rglob("*")):
            if p.is_file():
                z.write(p, p.relative_to(root).as_posix())
    shutil.rmtree(work, ignore_errors=True)
    print(f"==> {out} ({out.stat().st_size // (1024 * 1024)} MB)")


if __name__ == "__main__":
    main()
