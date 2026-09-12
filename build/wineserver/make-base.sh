#!/usr/bin/env bash
# Create the base libwineserver.a that build.sh patches but cannot produce.
#
# build.sh compiles 19 files and REPLACES those objects inside an existing
# archive:
#
#   if [ ! -f "$OBJ_DIR/libwineserver.a" ]; then
#       if [ -f "$APP_LIB" ]; then cp "$APP_LIB" "$OBJ_DIR/libwineserver.a"
#       else echo "ERROR: No base libwineserver.a found"; exit 1; fi
#   fi
#
# The base holds the other ~25 of wine/server's 44 sources. It is not committed
# and no script here creates it, which is why the app cannot be linked from a
# clean checkout. Every compile flag needed is in build.sh though, so the base
# can simply be built: compile all upstream server sources with those flags and
# archive them. build.sh then overwrites its 19 exactly as designed.
#
# Files that build.sh takes from $BUILD_DIR (*_ios.c) rather than upstream are
# still compiled here from their upstream originals -- they get replaced
# afterwards, so a failure on one of those is harmless. Failures are therefore
# reported but not fatal; what matters is whether the final app link resolves.
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
WINE_SRC="$REPO_ROOT/wine"
SHIMS_DIR="$REPO_ROOT/build/ntdll-unix/shims"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OBJ_DIR="$BUILD_DIR/base-obj"
APP_LIB="$REPO_ROOT/app/Madeira/libwineserver.a"

if [ ! -d "$WINE_SRC/server" ]; then
  echo "wine submodule not checked out: $WINE_SRC" >&2
  exit 1
fi
if [ ! -f "$WINE_SRC/build-macos/include/config.h" ]; then
  echo "wine/build-macos not configured -- run the wine configure stage first" >&2
  exit 1
fi

mkdir -p "$OBJ_DIR"

# Identical to build.sh's CC_FLAGS. Kept in sync by hand; if build.sh changes
# its flags this must follow, or the base and the replacements will disagree.
CC_FLAGS=(
    -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2
    -I"$WINE_SRC/include" -I"$WINE_SRC/include/wine"
    -I"$WINE_SRC/build-macos/include"
    -I"$BUILD_DIR" -I"$WINE_SRC/server"
    -I"$SHIMS_DIR"
    -include "$BUILD_DIR/config_ios.h"
    -include stdarg.h
    -include "$BUILD_DIR/unicode_fix.h"
    -include "$BUILD_DIR/wineserver_ios_kill.h"
    -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\"
    -D__WINESRC__ -DWINE_IOS=1
    -Dmain=wineserver_main
    -Wno-implicit-function-declaration
)

ok=0
fail=0
failed_names=""

for src in "$WINE_SRC"/server/*.c; do
  name="$(basename "$src" .c)"
  if xcrun -sdk iphoneos clang "${CC_FLAGS[@]}" -c "$src" \
       -o "$OBJ_DIR/$name.o" 2>"$OBJ_DIR/$name.err"; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
    failed_names="$failed_names $name"
  fi
done

echo "compiled $ok, failed $fail"
if [ "$fail" -gt 0 ]; then
  echo "failed:$failed_names"
  echo "--- first errors ---"
  for n in $failed_names; do
    echo "  $n:"
    grep -E 'error:|fatal error:' "$OBJ_DIR/$n.err" | head -3 | sed 's/^/      /' || true
  done
fi

if [ "$ok" -eq 0 ]; then
  echo "nothing compiled; not creating an archive" >&2
  exit 1
fi

rm -f "$OBJ_DIR/libwineserver.a"
ar rcs "$OBJ_DIR/libwineserver.a" "$OBJ_DIR"/*.o
mkdir -p "$(dirname "$APP_LIB")"
cp "$OBJ_DIR/libwineserver.a" "$APP_LIB"

echo "base archive: $APP_LIB"
ls -lh "$APP_LIB"
echo "objects: $(ar t "$APP_LIB" | wc -l | tr -d ' ')"
