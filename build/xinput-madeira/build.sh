#!/bin/bash
# Build Madeira's XInput DLLs (ARM64X hybrids) with llvm-mingw.
# Output: out/xinput1_1.dll xinput1_2.dll xinput1_3.dll xinput1_4.dll xinput9_1_0.dll
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/out}"
CC="${CC:-arm64ec-w64-mingw32-clang}"
mkdir -p "$OUT"

for name in xinput1_1 xinput1_2 xinput1_3 xinput1_4 xinput9_1_0; do
    def="$OUT/$name.def"
    # Ordinals follow Microsoft's: 1-8 named, 100-104/108 unnamed (games import
    # XInputGetStateEx by ordinal 100).
    cat > "$def" <<DEF
LIBRARY $name.dll
EXPORTS
    DllMain @1 PRIVATE
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
DEF
    "$CC" -O2 -shared -marm64x -Wall -Wno-unused-parameter \
        -o "$OUT/$name.dll" "$HERE/xinput.c" "$def" \
        -Wl,--no-insert-timestamp -s
    echo "built $OUT/$name.dll ($(wc -c < "$OUT/$name.dll") bytes)"
done
