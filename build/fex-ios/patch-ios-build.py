#!/usr/bin/env python3
"""Make the FEX fork's committed tree compile for iOS.

The fork's ios-port-2607 branch does not build as checked out. Its CMakeLists
genuinely supports iOS -- "FEX only supports Linux, Windows, and Darwin/iOS" --
and with the right invocation (see toolchain_ios.cmake) configure succeeds. But
some committed source references Windows APIs from translation units that never
include windows.h, outside any preprocessor guard. The author must have local
state, or builds FEX in a Windows-targeting configuration that supplies those
headers.

These patches are idempotent and touch diagnostics only -- no emulation
behaviour changes. Run before configuring; running twice is harmless.
"""
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
FEX = REPO / "FEX"

applied, skipped, failed = [], [], []


def patch(relpath: str, old: str, new: str, why: str) -> None:
    f = FEX / relpath
    if not f.exists():
        failed.append(f"{relpath}: file not found")
        return
    text = f.read_text(encoding="utf-8", errors="surrogateescape")
    if new in text:
        skipped.append(f"{relpath}: already patched ({why})")
        return
    if old not in text:
        failed.append(f"{relpath}: anchor not found ({why}) -- upstream changed?")
        return
    f.write_text(text.replace(old, new, 1), encoding="utf-8", errors="surrogateescape")
    applied.append(f"{relpath}: {why}")


# ---------------------------------------------------------------------------
# Arm64.cpp: VirtualQuery / MEMORY_BASIC_INFORMATION in a [caspal128] diagnostic.
#
#   Arm64.cpp:707: error: unknown type name 'MEMORY_BASIC_INFORMATION'
#   Arm64.cpp:709: error: unknown type name 'LPCVOID'
#   Arm64.cpp:710: error: use of undeclared identifier 'MEM_IMAGE' / 'MEM_MAPPED'
#
# Unguarded, and the file includes no Windows header. The block only enriches a
# log line describing which memory region an unexpected aligned-LSE fault landed
# in, so on non-Windows we keep the log and report the region as unavailable.
# ---------------------------------------------------------------------------
patch(
    "FEXCore/Source/Utils/ArchHelpers/Arm64.cpp",
    """  MEMORY_BASIC_INFORMATION mbi {};
  const char* type = "?";
  if (VirtualQuery(reinterpret_cast<LPCVOID>(GPRs[AddressReg]), &mbi, sizeof(mbi))) {
    type = mbi.Type == MEM_IMAGE ? "MEM_IMAGE" : mbi.Type == MEM_MAPPED ? "MEM_MAPPED" : "MEM_PRIVATE";
  }""",
    """#if defined(_WIN32)
  MEMORY_BASIC_INFORMATION mbi {};
  const char* type = "?";
  if (VirtualQuery(reinterpret_cast<LPCVOID>(GPRs[AddressReg]), &mbi, sizeof(mbi))) {
    type = mbi.Type == MEM_IMAGE ? "MEM_IMAGE" : mbi.Type == MEM_MAPPED ? "MEM_MAPPED" : "MEM_PRIVATE";
  }
#else
  /* iOS/Darwin: VirtualQuery is a Win32 API and this TU includes no Windows
   * header. The report below is diagnostic only, so keep the message and say
   * the region details are unavailable rather than dropping the log. */
  struct {
    const void* BaseAddress {};
    size_t RegionSize {};
    uint32_t Protect {};
    uint32_t State {};
  } mbi {};
  const char* type = "n/a";
#endif""",
    "guard the VirtualQuery [caspal128] region report",
)


# ---------------------------------------------------------------------------
# LinkerGC.cmake: GNU ld flags applied unconditionally in Release.
#
#   ld: unknown options: --gc-sections --strip-all --as-needed
#
# Apple's linker takes none of the three. They are size/link-time optimisations
# only, so dropping them on Apple costs nothing but a slightly larger binary.
# ---------------------------------------------------------------------------
patch(
    "Data/CMake/LinkerGC.cmake",
    """macro(LinkerGC target)
  if (CMAKE_BUILD_TYPE MATCHES "RELEASE")""",
    """macro(LinkerGC target)
  # Apple's ld accepts none of --gc-sections / --strip-all / --as-needed.
  if (CMAKE_BUILD_TYPE MATCHES "RELEASE" AND NOT APPLE)""",
    "skip GNU-only linker flags on Apple",
)


for line in applied:
    print(f"  applied  {line}")
for line in skipped:
    print(f"  skipped  {line}")
for line in failed:
    print(f"  FAILED   {line}")

if failed:
    print("\nOne or more patches did not apply. The FEX submodule has probably moved;")
    print("re-derive the anchors before trusting this build.", file=sys.stderr)
    sys.exit(1)

print(f"\n{len(applied)} applied, {len(skipped)} already present")
