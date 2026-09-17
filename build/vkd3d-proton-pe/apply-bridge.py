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
