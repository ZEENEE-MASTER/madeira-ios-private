#!/usr/bin/env bash
# Build FEXCore for iOS into FEX/build-ios/.
#
# The output directory is not a free choice: app/Madeira.xcodeproj hardcodes
# $(SRCROOT)/../FEX/build-ios in both HEADER_SEARCH_PATHS and
# LIBRARY_SEARCH_PATHS, and expects
#
#   FEX/build-ios/include/FEXCore/Config/ConfigValues.inl   (generated)
#   FEX/build-ios/FEXCore/Source/libFEXCore.a
#   FEX/build-ios/FEXCore/Source/libFEXCore_Base.a
#   FEX/build-ios/External/{fmt,cephes,xxhash/cmake_unofficial,SoftFloat-3e}/*.a
#
# Upstream has no equivalent of this script; the invocation lived only on the
# author's machine.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
FEX="$REPO_ROOT/FEX"
BUILD="$FEX/build-ios"

[ -d "$FEX/FEXCore" ] || { echo "FEX submodule not checked out: $FEX" >&2; exit 1; }

# Scripts/aarch64_fit_native.py prefers packaging.version and falls back to
# pkg_resources, which setuptools 81+ removed. Without either, the script emits
# nothing and CMakeLists.txt:510 string(STRIP) fails on an empty argument.
python3 -c 'import packaging' 2>/dev/null || {
  echo "python 'packaging' module missing; install it (brew install python-packaging)" >&2
  exit 1
}

# The fork's committed tree has unguarded Windows API calls in files that do not
# include windows.h. Idempotent, diagnostics only.
python3 "$HERE/patch-ios-build.py"

GEN=Ninja
command -v ninja >/dev/null 2>&1 || GEN="Unix Makefiles"

cmake -S "$FEX" -B "$BUILD" -G "$GEN" \
  -DCMAKE_TOOLCHAIN_FILE="$HERE/toolchain_ios.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_TESTING=OFF \
  -DBUILD_FEX_LINUX_TESTS=OFF \
  -DENABLE_JEMALLOC=OFF \
  -DENABLE_JEMALLOC_GLIBC_ALLOC=OFF \
  -DENABLE_FEX_ALLOCATOR=OFF \
  -DENABLE_LTO=OFF \n  -DTUNE_CPU=none \n  -DTUNE_ARCH=generic \
  "$@"

# Build only the STATIC targets the Xcode project links. The FEXCore_shared
# dylib cannot link on iOS and is not needed:
#   _ios_fex_mono_bridge_armed, _ios_fex_mono_take_pending, _rpm_cas_snapshot_take
#     -> defined in Source/Windows/ARM64EC/, which CMakeLists skips on Apple
#   _f128_mul, _extF80_to_i64, _f64_to_extF80, ...
#     -> External/SoftFloat-3e, not linked into the shared target
# libFEXCore.a already built fine at step 168/169; only 169 (the dylib) failed.
cmake --build "$BUILD" --parallel "$(sysctl -n hw.ncpu 2>/dev/null || nproc)" --target FEXCore FEXCore_Base

echo "--- produced ---"
find "$BUILD" -name '*.a' | sed "s|$BUILD/|  |"
