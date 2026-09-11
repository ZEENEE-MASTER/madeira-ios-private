# Build notes (private fork)

What it actually takes to build Madeira from a clean checkout, worked out by
running it in CI seven times. Upstream has no build documentation beyond
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
| 7 | *(not yet reached)* `libFEXCore.a` etc. | **FEX is not prebuilt** | see below |

## The real gate: FEX must be cross-compiled for iOS

`app/Madeira.xcodeproj` expects a populated `FEX/build-ios/`:

```
HEADER_SEARCH_PATHS   .../FEX/build-ios
                      .../FEX/build-ios/include          <- ConfigValues.inl lands here
                      .../FEX/build-ios/FEXCore/Source
LIBRARY_SEARCH_PATHS  .../FEX/build-ios/FEXCore/Source   <- libFEXCore.a, libFEXCore_Base.a
                      .../FEX/build-ios/External/fmt
                      .../FEX/build-ios/External/cephes
                      .../FEX/build-ios/External/xxhash/cmake_unofficial
                      .../FEX/build-ios/External/SoftFloat-3e
```

None of those libraries are committed. The only `.a` files in the repo are
`libgmp`, `libgnutls`, `libhogweed`, `libnettle` and `libdxmt_unix` — so DXMT,
wineserver and the crypto stack are prebuilt, **but FEXCore is not**.

There is no `build/fex-ios/build.sh`, and the FEX fork
(`willfaust/FEX @ ios-port-2607`) has no iOS toolchain file — `Data/CMake/`
carries `toolchain_aarch64`, `toolchain_mingw`, `toolchain_x86_32`,
`toolchain_x86_64` and nothing for iOS. It does carry iOS *source*
(`Source/Windows/ARM64EC/IosJitAlias.cpp`, `IosMonoBridge.h`,
`Source/Windows/Common/CRT/CRT_iOS.cpp`), so the port is real — the build
invocation for it is simply not in any repo.

**Someone has to write that CMake cross-compile, or get the author's.**

### ConfigValues.inl, for when that happens

It is generated during CMake configure, from `FEXCore/Source/CMakeLists.txt`:

```cmake
configure_file(${CMAKE_CURRENT_SOURCE_DIR}/Interface/Config/Config.json.in
               ${CMAKE_BINARY_DIR}/generated/Config/Config.json)

add_custom_command(
  OUTPUT "${OUTPUT_CONFIG_NAME}"        # ${CMAKE_BINARY_DIR}/include/FEXCore/Config/ConfigValues.inl
  OUTPUT "${OUTPUT_CONFIG_OPTION_NAME}" # ${CMAKE_BINARY_DIR}/include/FEXCore/Config/ConfigOptions.inl
  OUTPUT "${OUTPUT_MAN_NAME}"           # ${CMAKE_BINARY_DIR}/generated/FEX.1
  COMMAND "python3" ".../Scripts/config_generator.py"
    "${INPUT_CONFIG_NAME}" "${OUTPUT_CONFIG_NAME}" "${OUTPUT_MAN_NAME}"
    "${OUTPUT_CONFIG_OPTION_NAME}")
```

With `CMAKE_BINARY_DIR = FEX/build-ios`, a configure alone produces the two
`.inl` files. It does not produce the libraries.

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
