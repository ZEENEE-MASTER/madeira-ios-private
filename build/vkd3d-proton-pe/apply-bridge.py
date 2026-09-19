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

# Madeira: MoltenVK has no transform feedback (VK_EXT_transform_feedback backs
# D3D12 stream output). vkd3d-proton 3.0.1 treats it as a hard device-caps
# requirement and returns E_INVALIDARG, so D3D12CreateDevice fails on iOS even
# though the instance + physical device now come up. Make it non-fatal: disable
# stream output and let the device be created. Games that use stream output /
# geometry-shader SO will lack it; everything else runs.
patch(vkd3d / "device.c",
      "    if (!physical_device_info->xfb_properties.transformFeedbackQueries)\n"
      "    {\n"
      "        ERR(\"Lacking support for transform feedback.\\n\");\n"
      "        return E_INVALIDARG;\n"
      "    }\n",
      "    if (!physical_device_info->xfb_properties.transformFeedbackQueries)\n"
      "    {\n"
      "        /* Madeira: MoltenVK has no transform feedback. D3D12 stream output\n"
      "           is unavailable, but let the device come up so everything else runs. */\n"
      "        WARN(\"Transform feedback unsupported (MoltenVK); stream output disabled.\\n\");\n"
      "        vulkan_info->EXT_transform_feedback = false;\n"
      "        physical_device_info->xfb_features.transformFeedback = VK_FALSE;\n"
      "    }\n",
      "Madeira: MoltenVK has no transform feedback")

# Madeira: MoltenVK reports coarser texel-buffer offset alignment than "single
# texel", which vkd3d-proton 3.0.1 treats as a hard requirement (E_INVALIDARG).
# Relax it so the device is created; typed-buffer views at arbitrary byte
# offsets may be affected, but that is rare and not worth blocking all of DX12.
patch(vkd3d / "device.c",
      "    if (!single_storage_texel || !single_uniform_texel)\n"
      "    {\n"
      "        ERR(\"Lacking support for single texel alignment.\\n\");\n"
      "        return E_INVALIDARG;\n"
      "    }\n",
      "    if (!single_storage_texel || !single_uniform_texel)\n"
      "    {\n"
      "        /* Madeira: MoltenVK lacks single-texel alignment; allow the device. */\n"
      "        WARN(\"Single texel alignment unsupported (MoltenVK); allowing device anyway.\\n\");\n"
      "    }\n",
      "Madeira: MoltenVK lacks single-texel alignment")

# Madeira: this MoltenVK build does not expose VK_EXT_robustness2
# (robustBufferAccess2 / robustImageAccess2 / nullDescriptor all false), which
# vkd3d-proton requires. Relax both checks so the device is created, and turn
# on core 1.0 robustBufferAccess (which MoltenVK does support) so out-of-bounds
# buffer reads are still bounded. Null-descriptor access remains undefined.
patch(vkd3d / "device.c",
      "    if (!physical_device_info->robustness2_features.robustBufferAccess2 ||\n"
      "            !physical_device_info->robustness2_features.robustImageAccess2)\n"
      "    {\n"
      "        ERR(\"Robustness2 features not supported. This is required.\\n\");\n"
      "        return E_INVALIDARG;\n"
      "    }\n",
      "    if (!physical_device_info->robustness2_features.robustBufferAccess2 ||\n"
      "            !physical_device_info->robustness2_features.robustImageAccess2)\n"
      "    {\n"
      "        /* Madeira: MoltenVK lacks VK_EXT_robustness2; fall back to core\n"
      "           robustBufferAccess so out-of-bounds buffer reads stay bounded. */\n"
      "        WARN(\"Robustness2 unsupported (MoltenVK); using core robustBufferAccess.\\n\");\n"
      "        features->robustBufferAccess = VK_TRUE;\n"
      "    }\n",
      "Madeira: MoltenVK lacks VK_EXT_robustness2")

patch(vkd3d / "device.c",
      "    if (!physical_device_info->robustness2_features.nullDescriptor)\n"
      "    {\n"
      "        ERR(\"Null descriptor in VK_EXT_robustness2 is not supported by this implementation. This is required for correct operation.\\n\");\n"
      "        return E_INVALIDARG;\n"
      "    }\n",
      "    if (!physical_device_info->robustness2_features.nullDescriptor)\n"
      "    {\n"
      "        /* Madeira: no nullDescriptor on MoltenVK; unbound-descriptor access\n"
      "           is undefined, but let the device come up. */\n"
      "        WARN(\"Null descriptor unsupported (MoltenVK); allowing device anyway.\\n\");\n"
      "    }\n",
      "Madeira: no nullDescriptor on MoltenVK")

# Madeira: with the caps gates cleared, device creation now fails inside
# vkd3d_dstorage_ops_init: MoltenVK cannot compile cs_emit_nv_memory_decompression
# (SPIRV-Cross emits an atomic on a non-atomic buffer field -> Metal shader
# compile error 3 -> VK_ERROR_INITIALIZATION_FAILED -> device create fails).
# GPU DirectStorage decompression is not needed to render, so skip the whole
# thing. (void) casts keep the now-unused locals from tripping -Werror.
patch(vkd3d / "meta.c",
      "    if (!device->device_info.features2.features.shaderInt64)\n"
      "        return S_OK;\n",
      "    if (!device->device_info.features2.features.shaderInt64)\n"
      "        return S_OK;\n"
      "\n"
      "    /* Madeira: MoltenVK cannot compile vkd3d's memory-decompression compute\n"
      "       shaders (atomic on a non-atomic buffer field -> Metal rejects it),\n"
      "       which failed device creation. DirectStorage GPU decompression is not\n"
      "       needed to render, so skip these pipelines entirely. */\n"
      "    (void)required_size; (void)push_range; (void)force_wave32; (void)vr;\n"
      "    (void)gdeflate_subgroup_ops;\n"
      "    return S_OK;\n",
      "Madeira: MoltenVK cannot compile vkd3d's memory-decompression")
