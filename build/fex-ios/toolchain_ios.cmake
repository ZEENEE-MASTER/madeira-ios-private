# iOS cross-compile toolchain for FEXCore.
#
# The FEX fork supports iOS in its own CMakeLists ("FEX only supports Linux,
# Windows, and Darwin/iOS"), and on Apple it skips Source/ and builds FEXCore/
# alone -- which is exactly the libFEXCore.a / libFEXCore_Base.a that
# app/Madeira.xcodeproj links. What was missing was this file.
#
# Data/CMake/ in the FEX fork has toolchain_aarch64, toolchain_mingw,
# toolchain_x86_32 and toolchain_x86_64, and nothing for iOS. This fills that
# gap without modifying the submodule.
#
# CMAKE_SYSTEM_PROCESSOR specifically must be set HERE and not with -D on the
# command line: passing it as -DCMAKE_SYSTEM_PROCESSOR=aarch64 is overwritten
# during iOS platform initialisation, leaving FEX's
#
#   string(TOLOWER ${CMAKE_SYSTEM_PROCESSOR} processor)
#
# with an empty variable -- a call with no arguments, which is why configure
# reported both "string no output variable specified" and "Unsupported
# processor type ." from a single cause.

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "")
set(CMAKE_OSX_SYSROOT iphoneos CACHE STRING "")
set(CMAKE_OSX_DEPLOYMENT_TARGET "17.0" CACHE STRING "")

# Device build, never the simulator.
set(CMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH NO)

# Search host paths for programs, target paths for everything else.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM BEFORE)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# FEX defaults to TUNE_CPU=native, which runs
#   Scripts/aarch64_fit_native.py /proc/cpuinfo
# to pick an -mcpu= value. There is no /proc/cpuinfo on macOS, so the script
# dies and CMakeLists.txt:510 string(STRIP) is handed an empty argument.
#
# "none" is FEX's own escape hatch -- CMakeLists.txt:530 reads
#   elseif (NOT TUNE_CPU STREQUAL "none")
# so this skips CPU tuning entirely. Correct for a cross-compile regardless:
# the build host's CPU says nothing about the phone's.
set(TUNE_CPU "none" CACHE STRING "" FORCE)
set(TUNE_ARCH "generic" CACHE STRING "" FORCE)
