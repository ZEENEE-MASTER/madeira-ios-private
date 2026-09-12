# Build notes (private fork)

What it actually takes to build Madeira from a clean checkout, worked out by
running it in CI repeatedly. Upstream has no build documentation beyond
"shell scripts in `build/*/`, app via Xcode", so this is the missing half.

## Prerequisites, in the order they bite

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | `lstat(app/Madeira/x86_64-vcruntime): No such file or directory` | Xcode copies it as a resource; it is gitignored (Microsoft redistributables) | supply the 12 CRT DLLs |
| 2 | `.cab` glob matches nothing | `tools/fetch-vcruntime.md` points at `.rsrc/1033/CABINET/*.cab`, which no longer exists | — |
| 3 | 25 MB installer yields ~590 KB of `u1..u29` | `VC_redist.x64.exe` is a WiX burn bundle; 7-Zip will not open the attached container | take the DLLs from a Windows runner's Visual Studio redist instead |
| 4 | `no member 'glassEffect'` | `ContentView.swift` uses the iOS 26 Liquid Glass API | Xcode 26 / iOS 26 SDK required |
| 5 | `'FEXCore/Config/Config.h' file not found` | submodules not checked out | `submodules: recursive` — the committed `.a` files cover the link, not the compile |
| 6 | `'FEXCore/Config/ConfigValues.inl' file not found` | generated file, not in the tree | see below |
| 7 | `libFEXCore.a` not found | FEX is not prebuilt and has no build recipe | **solved** — `build/fex-ios/`, see below |

## FEX for iOS — SOLVED

`app/Madeira.xcodeproj` links `libFEXCore.a` and `libFEXCore_Base.a` from
`FEX/build-ios/`, and nothing in any repo builds them. I first recorded this as
"someone has to write that CMake cross-compile, or get the author's." **That was
wrong.** The FEX fork's own top-level `CMakeLists.txt` says:

```
"FEX only supports Linux, Windows, and Darwin/iOS."
CMAKE_SYSTEM_NAME STREQUAL "iOS"

if (NOT APPLE)
  # binfmt_misc, Source/, AppConfig     <- skipped on Apple
endif()
```

iOS is a supported system, and on Apple it skips `Source/` and builds `FEXCore/`
alone — exactly the two static libraries the app wants. Only the *invocation*
was missing. It now lives in `build/fex-ios/`:

| file | what it is |
|---|---|
| `toolchain_ios.cmake` | the toolchain upstream never had |
| `build.sh` | the invocation; every other component has one, FEX didn't |
| `patch-ios-build.py` | two idempotent source fixes |

### The six things it needed, and why each is non-obvious

1. **`CMAKE_SYSTEM_PROCESSOR=aarch64` from a toolchain file.** `CMAKE_SYSTEM_NAME=iOS`
   doesn't populate it, and passing `-DCMAKE_SYSTEM_PROCESSOR` on the command line
   is *overwritten during iOS platform initialisation*. FEX's first use is
   `string(TOLOWER ${CMAKE_SYSTEM_PROCESSOR} processor)` — with an empty variable
   that's a call with no arguments, so you get two errors from one cause:
   `string no output variable specified` and `Unsupported processor type .`

2. **`TUNE_CPU=none`.** FEX defaults to `native` and runs
   `Scripts/aarch64_fit_native.py /proc/cpuinfo`, which macOS doesn't have. Its own
   escape hatch is `elseif (NOT TUNE_CPU STREQUAL "none")` at CMakeLists.txt:530.
   Correct for any cross-compile: the build host's CPU says nothing about the target's.

3. **`-DFEX_IOS_HOST=1`.** Used 14 times in `Core.cpp` alone and **defined in no
   CMakeLists in the tree** — the author passes it from his own shell. Some
   declarations sit inside `#ifdef FEX_IOS_HOST` while code using them does not,
   so without it you get `use of undeclared identifier 'IosFfsBypassLog'`.

4. **Python `packaging` on the build host.** `aarch64_fit_native.py` does
   `try: from packaging.version import Version / except: from pkg_resources import
   parse_version`. It *prefers* packaging. `pkg_resources` was removed in
   setuptools 81+, so installing setuptools cannot supply it — 84.0.0 installs
   cleanly and the import still fails.

5. **Two source patches** (`patch-ios-build.py`, diagnostics only):
   * `Arm64.cpp` calls `VirtualQuery` with `MEMORY_BASIC_INFORMATION`/`LPCVOID`
     inside **no preprocessor guard**, in a file that includes no Windows header.
     The committed branch therefore cannot compile as checked out — the author has
     local state, or builds FEX in a Windows-targeting configuration.
   * `Data/CMake/LinkerGC.cmake` applies `--gc-sections --strip-all --as-needed`
     in Release with no platform guard; Apple's `ld` takes none of them.

6. **`--target FEXCore FEXCore_Base`.** The `FEXCore_shared` dylib cannot link on
   iOS — it needs `_ios_fex_mono_*` and `_rpm_cas_snapshot_take` from
   `Source/Windows/ARM64EC/` (skipped on Apple) and SoftFloat symbols that aren't
   linked into it. **This is what "failed" for four consecutive runs while
   `libFEXCore.a` was succeeding at step 168/169 in every one of them.**

### Output

```
libFEXCore.a           3.9M      libcephes_128bit.a   23K
libFEXCore_Base.a      124K      libxxhash.a          44K
libfmt.a               188K      libsoftfloat_3e.a    76K
```

Note the real filenames: `libcephes_128bit.a` and `libsoftfloat_3e.a`, not
`libcephes.a` / `libsoftfloat-3e.a`.

### ConfigValues.inl

Generated by an `add_custom_command` at **build** time, not configure — from
`FEXCore/Source/CMakeLists.txt`:

```cmake
configure_file(Interface/Config/Config.json.in
               ${CMAKE_BINARY_DIR}/generated/Config/Config.json)
add_custom_command(
  OUTPUT ${CMAKE_BINARY_DIR}/include/FEXCore/Config/ConfigValues.inl
  COMMAND python3 Scripts/config_generator.py ...)
```

## Known-good environment

* runner: `macos-latest` (Xcode 26.6, iOS SDK 26.5) — `macos-15` is too old
* scheme: `Madeira`, bundle id `com.willfaust.mythicemu`
* submodule sizes after shallow checkout: FEX 1.3 GB, wine 333 MB, dxmt 18 MB
* entitlements for sideloading: `get-task-allow` (StikDebug attaches to grant
  JIT; without it FEX cannot generate code and nothing runs),
  `increased-memory-limit`, `extended-virtual-addressing`

## Device notes carried over from the CP2077 work

Measured on iPhone 17 Pro Max / A19 Pro, same signing setup:

* enforced process ceiling **6656 MB**; jetsam observed at 6211 MB
* `extended-virtual-addressing` is live — mappings land ~456 GB in, 17.1 GB of
  VA reserved. Upstream's `ARCHITECTURE_ANALYSIS.md` says free accounts cannot
  provision this; on this setup it works.
* A19 Pro has mesh shader hardware, which DXMT needs for geometry shaders
  (A17 Pro+). Upstream develops on A15, so this device clears a bar his does not.

---

# Tier 0: the missing Wine PE DLLs — DONE

`.github/workflows/wine-pe-dlls.yml`. Builds on **Linux**, in minutes, with no
Mac, Xcode or iOS SDK — the Windows-side DLLs are PE binaries cross-compiled
with llvm-mingw, so this is the one part of the stack not blocked behind FEX.

Produced and verified (run 34677859384):

```
xaudio2_7  xaudio2_8  xaudio2_9  x3daudio1_7  xapofx1_5
d3d8  d3d10  d3d10_1  ddraw
msvcp120  msvcr110  atl100  dxdiagn  wbemprox  xolehlp
winevulkan  vulkan-1
```

## ARM64X: there is no "missing arm64ec half"

The first attempt reported 17 DLLs for `aarch64-windows` and **zero** for
`arm64ec-windows`, with `No rule to make target
dlls/<m>/arm64ec-windows/<m>.dll` for every module — even though the arm64ec
`.o` rules were plainly there. That is not a failure. From `tools/makedep.c`:

```c
/* check for ARM64X setup */
if ((ec_arch = find_pe_arch( "arm64ec" )) && (arch = find_pe_arch( "aarch64" )))
{
    native_archs[ec_arch] = arch;
    hybrid_archs[arch] = ec_arch;
    strarray_add( &hybrid_target_flags[ec_arch], "-marm64x" );
}
```

With **both** arches enabled, Wine folds arm64ec into the aarch64 output and
emits a single **ARM64X hybrid** — one binary carrying both ARM64 and ARM64EC
code. So arm64ec has no separate `.dll` target by design.

Confirmed against the artifacts by parsing their PE headers:

```
dll                 machine    loadcfg   verdict
xaudio2_9.dll       ARM64          320   hybrid ARM64X (contains ARM64EC)
winevulkan.dll      ARM64          320   hybrid ARM64X (contains ARM64EC)
...all 17 identical
```

Load config size 0x140 is the ARM64X/CHPE-extended layout; pure ARM64 is
smaller. This is how Windows 11 ships its own system DLLs: one file serving
both ARM64 and ARM64EC processes.

**Practical upshot:** these 17 files can go into `arm64ec-windows/` as well as
`aarch64-windows/` — same bytes, both work. If separate per-arch binaries are
ever wanted instead, configure twice in separate build dirs
(`--enable-archs=aarch64` alone, then `--enable-archs=arm64ec` alone), which
avoids the ARM64X pairing entirely.

## Why XAudio2 was free

`dlls/xaudio2_9/Makefile.in`:

```
IMPORTS   = $(FAUDIO_PE_LIBS) advapi32 ole32 user32 uuid
EXTRAINCL = $(FAUDIO_PE_CFLAGS)
```

`FAUDIO_**PE**_LIBS`, and `libs/faudio` is bundled in the fork — FAudio compiles
*into* the PE DLL. No unixlib, no external dependency, no iOS-side work.

# Tier 1: already done upstream, by the author

I was wrong that Madeira had no audio. It has no audio `.drv` *file*, which is
what misled me — the driver is statically linked into the app via
`libntdll_unix.a`.

`build/ntdll-unix/audio_null_ios.c` is 1046 lines and, despite the name, is a
real driver: `kAudioUnitSubType_RemoteIO`, `AudioComponentInstanceNew`,
stream-format negotiation, a render callback, `AudioUnitInitialize`, and the
full WASAPI surface (`ios_get_endpoint_ids`, `ios_create_stream`, `ios_start`,
`ios_stop`, `ios_reset`). `wineios.drv` is a 24-line PE stub that exists only to
satisfy `mmdevapi`'s unixlib load.

So XAudio2 lands on a **working** chain: FAudio → mmdevapi → RemoteIO. Adding
those DLLs should produce real sound, not just unblock startup.

# Tier 2: PE half done, ICD is the wall

```
d3d12.dll  ->  libs/vkd3d  ->  vulkan-1  ->  winevulkan  ->  ICD
 shipped       bundled         BUILT         BUILT           MoltenVK
```

`.github/workflows/moltenvk-ios.yml` builds MoltenVK for iOS standalone — it
does not need the app to link, so it is the one part of Tier 2 provable without
FEX. It also reports, from the built library rather than from documentation,
whether `VK_EXT_mesh_shader` and `VK_KHR_ray_tracing_pipeline` are advertised.

**Not done, and not doable until the app links:** wiring MoltenVK into
winevulkan. On Unix, winevulkan's unixlib reaches an ICD through the Vulkan
loader. iOS has no loader and no dlopen of a system Vulkan, so MoltenVK must be
linked statically and handed to winevulkan directly. That needs the FEX gate
cleared first.

---

# Can an IPA be built from this repository? No.

Not because of a build flag. The app links four static libraries that are **not
committed and cannot be regenerated from what is here**.

```
ld: library 'JemallocLibs' not found    -> fixed (FEX target, now built)
ld: library 'wineserver' not found      -> cannot be fixed from this repo
```

## What the app links, and where each comes from

| library | source | state |
|---|---|---|
| `libFEXCore.a` `libFEXCore_Base.a` `libJemallocLibs.a` `libcephes_128bit.a` `libfmt.a` `libsoftfloat_3e.a` `libxxhash.a` | `FEX/build-ios/` | **solved** — `build/fex-ios/` |
| `libgmp.a` `libgnutls.a` `libhogweed.a` `libnettle.a` | committed in `app/Madeira/` | fine |
| `libntdll_unix.a` `libwin32u_unix.a` `libwineserver.a` `libdxmt_combined.a` | *nowhere* | **blocked** |

## Why the last row cannot be produced

Each build script depends on artifacts absent from the repository:

* `build/ntdll-unix/build.sh` — `wine/build-macos` (a macOS Wine build tree) and
  `toolchains/gnutls-ios`
* `build/win32u-unix/build.sh` — `wine/build-macos`, and freetype from `toolchains/`
* `build/dxmt-ios/build.sh` — `toolchains/llvm-project` and `toolchains/llvm-ios-build`,
  a custom LLVM cross-built for iOS
* `build/wineserver/build.sh` — the hard one:

```bash
APP_LIB="$REPO_ROOT/app/Madeira/libwineserver.a"
if [ ! -f "$OBJ_DIR/libwineserver.a" ]; then
    if [ -f "$APP_LIB" ]; then
        cp "$APP_LIB" "$OBJ_DIR/libwineserver.a"
    else
        echo "ERROR: No base libwineserver.a found"
        exit 1
    fi
fi
```

It **replaces objects inside an existing archive** and has no path to creating
one. The base archive is not in the repo.

`toolchains/` contains zero entries here; `wine/build-macos` is a build output
that was never committed. Note also that only `libdxmt_unix.a` is committed
while the project links `libdxmt_combined.a` — a different file.

## What it would take

1. Build Wine for **macOS** to produce `wine/build-macos` (feasible — the PE
   cross-build already works, see `wine-pe-dlls.yml`)
2. Run `build/gnutls-ios/build.sh` and `build/freetype-ios/build.sh` to populate
   `toolchains/`
3. Cross-build LLVM for iOS into `toolchains/llvm-ios-build` (large, but
   mechanical)
4. Then `ntdll-unix`, `win32u-unix`, `dxmt-ios`
5. `wineserver` remains genuinely unclear — its script cannot bootstrap its own
   base archive, so either that base has to come out of the macOS Wine build, or
   the script needs rewriting

Steps 1–4 are a substantial but tractable chain. Step 5 is the one that may need
the author.

---

# The four missing libraries — three built

Run `.github/workflows/unix-libs.yml` (stage 3). Everything below came from a
clean checkout; none of it was committed upstream.

| library | result |
|---|---|
| `libntdll_unix.a` | **built** — 30/30 modules |
| `libwin32u_unix.a` | **built** — 46/46 modules, freetype merged, 3.46 MB |
| `libwineserver.a` | **built** — 44/44 sources, 45 objects |
| `libdxmt_combined.a` | needs LLVM 15 for iOS (`llvm-ios.yml`) |

## Step 1 — wine/build-macos

Configure only; the unix scripts use it for headers, never for objects. Two
things were needed beyond a plain configure:

* **llvm-mingw on the macOS host.** Wine's configure refuses on an arm64 host
  without a PE cross-compiler, even when only headers are wanted:
  `configure: error: PE cross-compilation is required for aarch64`.
* **The IDL-derived headers, explicitly.** `make include` produces only
  `config.h`. win32u then fails 24 of 46 modules with
  `combaseapi.h:29: fatal error: 'objidlbase.h' file not found`. Walking
  `wine/include/*.idl` and making each `.h` generated **345 headers** and took
  win32u to 46/46. ntdll was unaffected because it never includes
  `combaseapi.h` — which is exactly why the failure split the way it did.

## Step 2 — toolchains/

`build/gnutls-ios/build.sh` works as-is (gmp → nettle → gnutls, all arm64).
`build/freetype-ios/build.sh` exits with `ERROR: clone freetype first`; its own
header names the command:

```
git clone --depth 1 --branch VER-2-13-3 https://github.com/freetype/freetype.git research/freetype
```

## Step 5 — the wineserver base, solved

`build/wineserver/build.sh` compiles 19 files and *replaces* those objects in an
existing archive, exiting with `ERROR: No base libwineserver.a found` when there
is none. The base holds the other ~25 of `wine/server`'s 44 sources and is not
committed — this was the single strongest reason the app could not be linked.

It did not need the author. Every flag is in `build.sh`, so
`build/wineserver/make-base.sh` compiles **all 44** upstream sources with
byte-identical flags and archives them; `build.sh` then overwrites its 19 as
designed. All 44 compiled on the first attempt, zero failures.

The flags are duplicated between the two scripts by necessity — if `build.sh`'s
`CC_FLAGS` ever change, `make-base.sh` must follow, or the base and the
replacements will disagree about struct layouts and the `-Dmain=wineserver_main`
rename.

## A trap worth remembering

A diagnostic step killed a **successful** build:

```
Results: 46 succeeded, 0 failed
libwin32u_unix.a: 3458608 bytes
Done!
=== first errors from failed win32u modules ===
--- class.err ---
##[error]Process completed with exit code 1
```

`class.err` existed but was empty, `grep 'error:'` matched nothing, exited 1, and
`set -euo pipefail` took the step down — which also prevented the wineserver
stage from running. Under `pipefail`, any grep that is *allowed* to find nothing
needs `|| true`.
