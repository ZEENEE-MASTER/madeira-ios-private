#!/usr/bin/env python3
"""Add Madeira's DXGI swapchain bridge (dxgi_bridge.c) to a vkd3d-proton checkout.

Usage: apply-bridge.py <vkd3d-proton source dir>

Three edits, each anchored on text that must exist exactly once, so a changed
upstream fails loudly here instead of producing a d3d12core.dll without the
bridge:
  1. copy dxgi_bridge.c into libs/d3d12core/
  2. add it to d3d12core_src in libs/d3d12core/meson.build
  3. call d3d12core_dxgi_bridge_install() after a D3D12 device is created
Idempotent: re-running on a patched tree changes nothing.
"""
import pathlib
import shutil
import sys

HERE = pathlib.Path(__file__).resolve().parent
src = pathlib.Path(sys.argv[1]).resolve()
core = src / "libs" / "d3d12core"


def patch(path, anchor, replacement, marker):
    text = path.read_text(encoding="utf-8")
    if marker in text:
        print(f"  {path.relative_to(src)}: already patched")
        return
    count = text.count(anchor)
    if count != 1:
        raise SystemExit(f"{path}: anchor found {count} times, expected 1:\n{anchor}")
    path.write_text(text.replace(anchor, replacement), encoding="utf-8", newline="\n")
    print(f"  {path.relative_to(src)}: patched")


shutil.copyfile(HERE / "dxgi_bridge.c", core / "dxgi_bridge.c")
print("  libs/d3d12core/dxgi_bridge.c: copied")

patch(core / "meson.build",
      "d3d12core_src = [\n  'debug.c',\n  'main.c'\n]",
      "d3d12core_src = [\n  'debug.c',\n  'main.c'\n]\n\n"
      "# Madeira: DXGI swapchains for D3D12 queues when dxgi.dll is DXMT's.\n"
      "if vkd3d_platform == 'windows'\n  d3d12core_src += 'dxgi_bridge.c'\nendif",
      "dxgi_bridge.c")

patch(core / "main.c",
      "HRESULT WINAPI DLLEXPORT D3D12GetInterface(REFCLSID rcslid, REFIID iid, void** debug);\n",
      "HRESULT WINAPI DLLEXPORT D3D12GetInterface(REFCLSID rcslid, REFIID iid, void** debug);\n"
      "#ifdef _WIN32\n"
      "void d3d12core_dxgi_bridge_install(IDXGIAdapter *adapter); /* Madeira: dxgi_bridge.c */\n"
      "#endif\n",
      "d3d12core_dxgi_bridge_install(IDXGIAdapter *adapter);")

patch(core / "main.c",
      "#ifdef _WIN32\n    passthrough_unix_environment(\"VKD3D_UNIX_POST_ENV\");\n",
      "#ifdef _WIN32\n"
      "    if (SUCCEEDED(hr))\n"
      "        d3d12core_dxgi_bridge_install(dxgi_adapter);\n"
      "    passthrough_unix_environment(\"VKD3D_UNIX_POST_ENV\");\n",
      "d3d12core_dxgi_bridge_install(dxgi_adapter);")

# Madeira: MoltenVK does not implement VK_KHR_cooperative_matrix. vkd3d-proton
# 3.0.1 loads vkGetPhysicalDeviceCooperativeMatrixPropertiesKHR through the
# REQUIRED instance-proc macro (the only extension proc that does), so the NULL
# lookup aborts instance creation entirely and NO D3D12 device is ever created
# on iOS (confirmed on device: hr 0x80004005, "Failed to load instance procs").
# Two edits make it degrade gracefully instead:
#   1. load the proc through the optional macro (every other ext proc uses it)
#   2. treat cooperative matrix as unsupported when the proc is NULL, so the
#      capability probe never calls through the NULL pointer
vkd3d = src / "libs" / "vkd3d"

patch(vkd3d / "vulkan_procs.h",
      "VK_INSTANCE_PFN(vkGetPhysicalDeviceCooperativeMatrixPropertiesKHR)",
      "VK_INSTANCE_EXT_PFN(vkGetPhysicalDeviceCooperativeMatrixPropertiesKHR)",
      "VK_INSTANCE_EXT_PFN(vkGetPhysicalDeviceCooperativeMatrixPropertiesKHR)")

patch(vkd3d / "device.c",
      "    fp8 = device->device_info.shader_float8_features.shaderFloat8CooperativeMatrix == VK_TRUE;\n",
      "    fp8 = device->device_info.shader_float8_features.shaderFloat8CooperativeMatrix == VK_TRUE;\n"
      "\n"
      "    /* Madeira: MoltenVK has no VK_KHR_cooperative_matrix, so the instance\n"
      "       proc is NULL. Treat cooperative matrix as unsupported instead of\n"
      "       calling through a NULL pointer. */\n"
      "    if (!vk_procs->vkGetPhysicalDeviceCooperativeMatrixPropertiesKHR)\n"
      "    {\n"
      "        WARN(\"vkGetPhysicalDeviceCooperativeMatrixPropertiesKHR unavailable; disabling cooperative matrix.\\n\");\n"
      "        return false;\n"
      "    }\n",
      "Madeira: MoltenVK has no VK_KHR_cooperative_matrix")
