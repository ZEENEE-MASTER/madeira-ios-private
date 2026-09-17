/*
 * DXGI swapchain bridge for vkd3d-proton on Madeira (compiled into d3d12core.dll).
 *
 * Why this exists
 * ---------------
 * vkd3d-proton does not implement DXGI. It exposes IDXGIVkSwapChainFactory on
 * its ID3D12CommandQueue and expects dxgi.dll to call it -- which DXVK's dxgi
 * does. Madeira's dxgi.dll is DXMT's, and DXMT's factory rejects anything that
 * is not a DXMT device:
 *
 *     if (FAILED(pDevice->QueryInterface(IID_PPV_ARGS(&metal_dxgi_device)))) {
 *       ERR("Unsupported device type");
 *       return DXGI_ERROR_UNSUPPORTED;
 *     }                                      (src/dxgi/dxgi_factory.cpp)
 *
 * Replacing dxgi.dll is not an option (DXMT's d3d11 depends on its own adapter
 * interfaces), so D3D12 swapchain creation would always fail.
 *
 * What it does
 * ------------
 * The first time a D3D12 device is created, the factory vtable that the game's
 * adapter belongs to gets two entries redirected: CreateSwapChain and
 * CreateSwapChainForHwnd. All instances of a COM class share one vtable, so this
 * covers factories the game already holds and ones it creates later.
 *
 * The hooks ALWAYS call the original first. Only when it fails AND the device is
 * a vkd3d-proton command queue (QueryInterface for IDXGIVkSwapChainFactory
 * succeeds) does the bridge build the swapchain itself: an IDXGISwapChain4 that
 * forwards to vkd3d-proton's IDXGIVkSwapChain, the same division of labour as
 * DXVK's DxgiSwapChain. D3D11 devices never reach the bridge, and with a dxgi
 * that handles D3D12 itself the original call succeeds and nothing changes.
 *
 * The surface comes from vkCreateWin32SurfaceKHR through vulkan-1/winevulkan,
 * which on iOS ends in win32u's Vulkan driver (build/win32u-unix/
 * vulkan_ios_drv.c) and a VK_EXT_metal_surface on the app's CAMetalLayer.
 *
 * VKD3D_DXGI_BRIDGE=0 disables it.
 *
 * iOS has one screen and no mode switching, so fullscreen state is recorded and
 * reported back but never changes the display.
 */

#define VKD3D_DBG_CHANNEL VKD3D_DBG_CHANNEL_API

#define VK_NO_PROTOTYPES
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "vkd3d_win32.h"
#include "vkd3d_debug.h"

void d3d12core_dxgi_bridge_install(IDXGIAdapter *adapter);

/* ------------------------------------------------------------------------- */
/* IDXGIVkSurfaceFactory                                                      */
/* ------------------------------------------------------------------------- */

struct bridge_surface_factory
{
    IDXGIVkSurfaceFactory IDXGIVkSurfaceFactory_iface;
    LONG refcount;
    HWND hwnd;
};

static inline struct bridge_surface_factory *impl_from_IDXGIVkSurfaceFactory(IDXGIVkSurfaceFactory *iface)
{
    return CONTAINING_RECORD(iface, struct bridge_surface_factory, IDXGIVkSurfaceFactory_iface);
}

static HRESULT STDMETHODCALLTYPE bridge_surface_factory_QueryInterface(IDXGIVkSurfaceFactory *iface,
        REFIID riid, void **object)
{
    if (!object)
        return E_POINTER;

    if (IsEqualGUID(riid, &IID_IUnknown) || IsEqualGUID(riid, &IID_IDXGIVkSurfaceFactory))
    {
        IDXGIVkSurfaceFactory_AddRef(iface);
        *object = iface;
        return S_OK;
    }

    *object = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE bridge_surface_factory_AddRef(IDXGIVkSurfaceFactory *iface)
{
    struct bridge_surface_factory *factory = impl_from_IDXGIVkSurfaceFactory(iface);
    return InterlockedIncrement(&factory->refcount);
}

static ULONG STDMETHODCALLTYPE bridge_surface_factory_Release(IDXGIVkSurfaceFactory *iface)
{
    struct bridge_surface_factory *factory = impl_from_IDXGIVkSurfaceFactory(iface);
    ULONG refcount = InterlockedDecrement(&factory->refcount);

    if (!refcount)
        free(factory);
    return refcount;
}

static VkResult STDMETHODCALLTYPE bridge_surface_factory_CreateSurface(IDXGIVkSurfaceFactory *iface,
        VkInstance instance, VkPhysicalDevice adapter, VkSurfaceKHR *surface)
{
    struct bridge_surface_factory *factory = impl_from_IDXGIVkSurfaceFactory(iface);
    VkResult (WINAPI *create_surface)(VkInstance, const VkWin32SurfaceCreateInfoKHR *,
            const VkAllocationCallbacks *, VkSurfaceKHR *);
    PFN_vkGetInstanceProcAddr get_instance_proc_addr = NULL;
    VkWin32SurfaceCreateInfoKHR create_info;
    HMODULE vulkan;
    VkResult vr;

    /* d3d12core.dll already loaded one of these (main.c vulkan_dllnames). */
    if ((vulkan = GetModuleHandleA("vulkan-1.dll")) || (vulkan = GetModuleHandleA("winevulkan.dll")))
        get_instance_proc_addr = (PFN_vkGetInstanceProcAddr)(void *)GetProcAddress(vulkan, "vkGetInstanceProcAddr");
    if (!get_instance_proc_addr)
    {
        ERR("dxgi bridge: no vkGetInstanceProcAddr.\n");
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    if (!(create_surface = (void *)get_instance_proc_addr(instance, "vkCreateWin32SurfaceKHR")))
    {
        ERR("dxgi bridge: instance has no vkCreateWin32SurfaceKHR.\n");
        return VK_ERROR_EXTENSION_NOT_PRESENT;
    }

    memset(&create_info, 0, sizeof(create_info));
    create_info.sType = VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR;
    create_info.hinstance = GetModuleHandleW(NULL);
    create_info.hwnd = factory->hwnd;

    vr = create_surface(instance, &create_info, NULL, surface);
    if (vr != VK_SUCCESS)
        ERR("dxgi bridge: vkCreateWin32SurfaceKHR failed, vr %d.\n", vr);
    else
        WARN("dxgi bridge: Vulkan surface created for hwnd %p.\n", factory->hwnd);
    return vr;
}

static CONST_VTBL struct IDXGIVkSurfaceFactoryVtbl bridge_surface_factory_vtbl =
{
    bridge_surface_factory_QueryInterface,
    bridge_surface_factory_AddRef,
    bridge_surface_factory_Release,
    bridge_surface_factory_CreateSurface,
};

/* ------------------------------------------------------------------------- */
/* IDXGISwapChain4 over IDXGIVkSwapChain                                      */
/* ------------------------------------------------------------------------- */

struct bridge_swapchain
{
    IDXGISwapChain4 IDXGISwapChain4_iface;
    LONG refcount;

    IDXGIFactory2 *factory;
    IDXGIVkSwapChain *presenter;
    IDXGIVkSwapChain1 *presenter1; /* optional: frame statistics */
    IDXGIVkSurfaceFactory *surface_factory;

    HWND hwnd;
    DXGI_SWAP_CHAIN_FULLSCREEN_DESC fullscreen_desc;
    BOOL fullscreen;
    IDXGIOutput *target;
    DXGI_RGBA background;
};

static inline struct bridge_swapchain *impl_from_IDXGISwapChain4(IDXGISwapChain4 *iface)
{
    return CONTAINING_RECORD(iface, struct bridge_swapchain, IDXGISwapChain4_iface);
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_QueryInterface(IDXGISwapChain4 *iface, REFIID riid, void **object)
{
    if (!object)
        return E_POINTER;

    if (IsEqualGUID(riid, &IID_IUnknown)
            || IsEqualGUID(riid, &IID_IDXGIObject)
            || IsEqualGUID(riid, &IID_IDXGIDeviceSubObject)
            || IsEqualGUID(riid, &IID_IDXGISwapChain)
            || IsEqualGUID(riid, &IID_IDXGISwapChain1)
            || IsEqualGUID(riid, &IID_IDXGISwapChain2)
            || IsEqualGUID(riid, &IID_IDXGISwapChain3)
            || IsEqualGUID(riid, &IID_IDXGISwapChain4))
    {
        IDXGISwapChain4_AddRef(iface);
        *object = iface;
        return S_OK;
    }

    WARN("dxgi bridge: unsupported interface %s.\n", debugstr_guid(riid));
    *object = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE bridge_swapchain_AddRef(IDXGISwapChain4 *iface)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);
    return InterlockedIncrement(&chain->refcount);
}

static ULONG STDMETHODCALLTYPE bridge_swapchain_Release(IDXGISwapChain4 *iface)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);
    ULONG refcount = InterlockedDecrement(&chain->refcount);

    if (!refcount)
    {
        if (chain->target)
            IDXGIOutput_Release(chain->target);
        if (chain->presenter1)
            IDXGIVkSwapChain1_Release(chain->presenter1);
        IDXGIVkSwapChain_Release(chain->presenter);
        /* After the presenter: it may still reference the surface factory. */
        IDXGIVkSurfaceFactory_Release(chain->surface_factory);
        IDXGIFactory2_Release(chain->factory);
        free(chain);
    }
    return refcount;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_SetPrivateData(IDXGISwapChain4 *iface,
        REFGUID guid, UINT data_size, const void *data)
{
    /* Almost always WKPDID_D3DDebugObjectName; nothing reads it back. */
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_SetPrivateDataInterface(IDXGISwapChain4 *iface,
        REFGUID guid, const IUnknown *object)
{
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_GetPrivateData(IDXGISwapChain4 *iface,
        REFGUID guid, UINT *data_size, void *data)
{
    if (data_size)
        *data_size = 0;
    return DXGI_ERROR_NOT_FOUND;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_GetParent(IDXGISwapChain4 *iface, REFIID riid, void **parent)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);
    return IDXGIFactory2_QueryInterface(chain->factory, riid, parent);
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_GetDevice(IDXGISwapChain4 *iface, REFIID riid, void **device)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);
    return IDXGIVkSwapChain_GetDevice(chain->presenter, riid, device);
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_Present1(IDXGISwapChain4 *iface,
        UINT sync_interval, UINT flags, const DXGI_PRESENT_PARAMETERS *present_parameters)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);

    if (sync_interval > 4)
        return DXGI_ERROR_INVALID_CALL;
    if (flags & DXGI_PRESENT_TEST)
        return S_OK;

    return IDXGIVkSwapChain_Present(chain->presenter, sync_interval, flags, present_parameters);
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_Present(IDXGISwapChain4 *iface, UINT sync_interval, UINT flags)
{
    return bridge_swapchain_Present1(iface, sync_interval, flags, NULL);
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_GetBuffer(IDXGISwapChain4 *iface,
        UINT buffer_idx, REFIID riid, void **surface)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);
    return IDXGIVkSwapChain_GetImage(chain->presenter, buffer_idx, riid, surface);
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_SetFullscreenState(IDXGISwapChain4 *iface,
        WINBOOL fullscreen, IDXGIOutput *target)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);

    if (chain->target)
        IDXGIOutput_Release(chain->target);
    if ((chain->target = fullscreen ? target : NULL))
        IDXGIOutput_AddRef(chain->target);

    chain->fullscreen = !!fullscreen;
    chain->fullscreen_desc.Windowed = !fullscreen;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_GetContainingOutput(IDXGISwapChain4 *iface, IDXGIOutput **output)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);
    IDXGIAdapter *adapter;
    HRESULT hr;

    if (!output)
        return E_POINTER;
    *output = NULL;

    if (chain->target)
    {
        IDXGIOutput_AddRef(chain->target);
        *output = chain->target;
        return S_OK;
    }

    if (FAILED(hr = IDXGIVkSwapChain_GetAdapter(chain->presenter, &IID_IDXGIAdapter, (void **)&adapter)))
        return hr;
    hr = IDXGIAdapter_EnumOutputs(adapter, 0, output);
    IDXGIAdapter_Release(adapter);
    return hr;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_GetFullscreenState(IDXGISwapChain4 *iface,
        WINBOOL *fullscreen, IDXGIOutput **target)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);

    if (fullscreen)
        *fullscreen = chain->fullscreen;
    if (target)
    {
        *target = NULL;
        if (chain->fullscreen)
            bridge_swapchain_GetContainingOutput(iface, target);
    }
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_GetDesc1(IDXGISwapChain4 *iface, DXGI_SWAP_CHAIN_DESC1 *desc)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);

    if (!desc)
        return E_INVALIDARG;
    return IDXGIVkSwapChain_GetDesc(chain->presenter, desc);
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_GetDesc(IDXGISwapChain4 *iface, DXGI_SWAP_CHAIN_DESC *desc)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);
    DXGI_SWAP_CHAIN_DESC1 desc1;
    HRESULT hr;

    if (!desc)
        return E_INVALIDARG;
    if (FAILED(hr = IDXGIVkSwapChain_GetDesc(chain->presenter, &desc1)))
        return hr;

    memset(desc, 0, sizeof(*desc));
    desc->BufferDesc.Width = desc1.Width;
    desc->BufferDesc.Height = desc1.Height;
    desc->BufferDesc.RefreshRate = chain->fullscreen_desc.RefreshRate;
    desc->BufferDesc.Format = desc1.Format;
    desc->BufferDesc.ScanlineOrdering = chain->fullscreen_desc.ScanlineOrdering;
    desc->BufferDesc.Scaling = chain->fullscreen_desc.Scaling;
    desc->SampleDesc = desc1.SampleDesc;
    desc->BufferUsage = desc1.BufferUsage;
    desc->BufferCount = desc1.BufferCount;
    desc->OutputWindow = chain->hwnd;
    desc->Windowed = chain->fullscreen_desc.Windowed;
    desc->SwapEffect = desc1.SwapEffect;
    desc->Flags = desc1.Flags;
    return S_OK;
}

static void bridge_window_size(HWND hwnd, UINT *width, UINT *height)
{
    RECT rect;

    if (!GetClientRect(hwnd, &rect))
        return;
    if (!*width)
        *width = rect.right > rect.left ? rect.right - rect.left : 1;
    if (!*height)
        *height = rect.bottom > rect.top ? rect.bottom - rect.top : 1;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_ResizeBuffers1(IDXGISwapChain4 *iface,
        UINT buffer_count, UINT width, UINT height, DXGI_FORMAT format, UINT flags,
        const UINT *node_mask, IUnknown *const *present_queue)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);
    DXGI_SWAP_CHAIN_DESC1 desc;
    HRESULT hr;

    if (FAILED(hr = IDXGIVkSwapChain_GetDesc(chain->presenter, &desc)))
        return hr;

    if (buffer_count)
        desc.BufferCount = buffer_count;
    desc.Width = width;
    desc.Height = height;
    bridge_window_size(chain->hwnd, &desc.Width, &desc.Height);
    if (format != DXGI_FORMAT_UNKNOWN)
        desc.Format = format;
    desc.Flags = flags;

    return IDXGIVkSwapChain_ChangeProperties(chain->presenter, &desc, node_mask, present_queue);
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_ResizeBuffers(IDXGISwapChain4 *iface,
        UINT buffer_count, UINT width, UINT height, DXGI_FORMAT format, UINT flags)
{
    return bridge_swapchain_ResizeBuffers1(iface, buffer_count, width, height, format, flags, NULL, NULL);
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_ResizeTarget(IDXGISwapChain4 *iface,
        const DXGI_MODE_DESC *target_mode_desc)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);

    if (!target_mode_desc)
        return DXGI_ERROR_INVALID_CALL;
    /* The window is the device screen; remember the requested mode only. */
    chain->fullscreen_desc.RefreshRate = target_mode_desc->RefreshRate;
    chain->fullscreen_desc.ScanlineOrdering = target_mode_desc->ScanlineOrdering;
    chain->fullscreen_desc.Scaling = target_mode_desc->Scaling;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_GetFrameStatistics(IDXGISwapChain4 *iface,
        DXGI_FRAME_STATISTICS *stats)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);
    DXGI_VK_FRAME_STATISTICS vk_stats;

    if (!stats)
        return E_INVALIDARG;
    if (!chain->presenter1)
        return DXGI_ERROR_FRAME_STATISTICS_DISJOINT;

    IDXGIVkSwapChain1_GetFrameStatistics(chain->presenter1, &vk_stats);
    memset(stats, 0, sizeof(*stats));
    stats->PresentCount = (UINT)vk_stats.PresentCount;
    stats->PresentRefreshCount = (UINT)vk_stats.PresentCount;
    stats->SyncRefreshCount = (UINT)vk_stats.PresentCount;
    stats->SyncQPCTime.QuadPart = (LONGLONG)vk_stats.PresentQPCTime;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_GetLastPresentCount(IDXGISwapChain4 *iface, UINT *last_present_count)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);
    UINT64 count = 0;

    if (!last_present_count)
        return E_INVALIDARG;
    if (chain->presenter1)
        IDXGIVkSwapChain1_GetLastPresentCount(chain->presenter1, &count);
    *last_present_count = (UINT)count;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_GetFullscreenDesc(IDXGISwapChain4 *iface,
        DXGI_SWAP_CHAIN_FULLSCREEN_DESC *desc)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);

    if (!desc)
        return E_INVALIDARG;
    *desc = chain->fullscreen_desc;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_GetHwnd(IDXGISwapChain4 *iface, HWND *hwnd)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);

    if (!hwnd)
        return E_INVALIDARG;
    *hwnd = chain->hwnd;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_GetCoreWindow(IDXGISwapChain4 *iface, REFIID riid, void **window)
{
    if (window)
        *window = NULL;
    return DXGI_ERROR_INVALID_CALL;
}

static WINBOOL STDMETHODCALLTYPE bridge_swapchain_IsTemporaryMonoSupported(IDXGISwapChain4 *iface)
{
    return FALSE;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_GetRestrictToOutput(IDXGISwapChain4 *iface, IDXGIOutput **output)
{
    if (!output)
        return E_INVALIDARG;
    *output = NULL;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_SetBackgroundColor(IDXGISwapChain4 *iface, const DXGI_RGBA *color)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);

    if (color)
        chain->background = *color;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_GetBackgroundColor(IDXGISwapChain4 *iface, DXGI_RGBA *color)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);

    if (!color)
        return E_INVALIDARG;
    *color = chain->background;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_SetRotation(IDXGISwapChain4 *iface, DXGI_MODE_ROTATION rotation)
{
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_GetRotation(IDXGISwapChain4 *iface, DXGI_MODE_ROTATION *rotation)
{
    if (!rotation)
        return E_INVALIDARG;
    *rotation = DXGI_MODE_ROTATION_IDENTITY;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_SetSourceSize(IDXGISwapChain4 *iface, UINT width, UINT height)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);
    DXGI_SWAP_CHAIN_DESC1 desc;

    if (FAILED(IDXGIVkSwapChain_GetDesc(chain->presenter, &desc)))
        return DXGI_ERROR_INVALID_CALL;
    if (!width || !height || width > desc.Width || height > desc.Height)
        return DXGI_ERROR_INVALID_CALL;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_GetSourceSize(IDXGISwapChain4 *iface, UINT *width, UINT *height)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);
    DXGI_SWAP_CHAIN_DESC1 desc;
    HRESULT hr;

    if (FAILED(hr = IDXGIVkSwapChain_GetDesc(chain->presenter, &desc)))
        return hr;
    if (width)
        *width = desc.Width;
    if (height)
        *height = desc.Height;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_SetMaximumFrameLatency(IDXGISwapChain4 *iface, UINT max_latency)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);

    if (max_latency > DXGI_MAX_SWAP_CHAIN_BUFFERS)
        return DXGI_ERROR_INVALID_CALL;
    return IDXGIVkSwapChain_SetFrameLatency(chain->presenter, max_latency ? max_latency : 3);
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_GetMaximumFrameLatency(IDXGISwapChain4 *iface, UINT *max_latency)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);

    if (!max_latency)
        return E_INVALIDARG;
    *max_latency = IDXGIVkSwapChain_GetFrameLatency(chain->presenter);
    return S_OK;
}

/* vkd3d-proton's GetFrameLatencyEvent already returns a DuplicateHandle()d
 * handle the caller owns, which is exactly DXGI's contract. */
static HANDLE STDMETHODCALLTYPE bridge_swapchain_GetFrameLatencyWaitableObject(IDXGISwapChain4 *iface)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);
    return IDXGIVkSwapChain_GetFrameLatencyEvent(chain->presenter);
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_SetMatrixTransform(IDXGISwapChain4 *iface,
        const DXGI_MATRIX_3X2_F *matrix)
{
    /* Composition swapchains only. */
    return DXGI_ERROR_INVALID_CALL;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_GetMatrixTransform(IDXGISwapChain4 *iface, DXGI_MATRIX_3X2_F *matrix)
{
    return DXGI_ERROR_INVALID_CALL;
}

static UINT STDMETHODCALLTYPE bridge_swapchain_GetCurrentBackBufferIndex(IDXGISwapChain4 *iface)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);
    return IDXGIVkSwapChain_GetImageIndex(chain->presenter);
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_CheckColorSpaceSupport(IDXGISwapChain4 *iface,
        DXGI_COLOR_SPACE_TYPE colour_space, UINT *colour_space_support)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);

    if (!colour_space_support)
        return E_INVALIDARG;
    *colour_space_support = IDXGIVkSwapChain_CheckColorSpaceSupport(chain->presenter, colour_space);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_SetColorSpace1(IDXGISwapChain4 *iface,
        DXGI_COLOR_SPACE_TYPE colour_space)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);
    return IDXGIVkSwapChain_SetColorSpace(chain->presenter, colour_space);
}

static HRESULT STDMETHODCALLTYPE bridge_swapchain_SetHDRMetaData(IDXGISwapChain4 *iface,
        DXGI_HDR_METADATA_TYPE type, UINT size, void *metadata)
{
    struct bridge_swapchain *chain = impl_from_IDXGISwapChain4(iface);
    DXGI_VK_HDR_METADATA vk_metadata;

    if (size && !metadata)
        return E_INVALIDARG;

    memset(&vk_metadata, 0, sizeof(vk_metadata));
    vk_metadata.Type = type;
    switch (type)
    {
        case DXGI_HDR_METADATA_TYPE_NONE:
            break;
        case DXGI_HDR_METADATA_TYPE_HDR10:
            if (size != sizeof(DXGI_HDR_METADATA_HDR10))
                return E_INVALIDARG;
            vk_metadata.HDR10 = *(DXGI_HDR_METADATA_HDR10 *)metadata;
            break;
        default:
            return E_INVALIDARG;
    }
    return IDXGIVkSwapChain_SetHDRMetaData(chain->presenter, &vk_metadata);
}

static CONST_VTBL IDXGISwapChain4Vtbl bridge_swapchain_vtbl =
{
    .QueryInterface = bridge_swapchain_QueryInterface,
    .AddRef = bridge_swapchain_AddRef,
    .Release = bridge_swapchain_Release,
    .SetPrivateData = bridge_swapchain_SetPrivateData,
    .SetPrivateDataInterface = bridge_swapchain_SetPrivateDataInterface,
    .GetPrivateData = bridge_swapchain_GetPrivateData,
    .GetParent = bridge_swapchain_GetParent,
    .GetDevice = bridge_swapchain_GetDevice,
    .Present = bridge_swapchain_Present,
    .GetBuffer = bridge_swapchain_GetBuffer,
    .SetFullscreenState = bridge_swapchain_SetFullscreenState,
    .GetFullscreenState = bridge_swapchain_GetFullscreenState,
    .GetDesc = bridge_swapchain_GetDesc,
    .ResizeBuffers = bridge_swapchain_ResizeBuffers,
    .ResizeTarget = bridge_swapchain_ResizeTarget,
    .GetContainingOutput = bridge_swapchain_GetContainingOutput,
    .GetFrameStatistics = bridge_swapchain_GetFrameStatistics,
    .GetLastPresentCount = bridge_swapchain_GetLastPresentCount,
    .GetDesc1 = bridge_swapchain_GetDesc1,
    .GetFullscreenDesc = bridge_swapchain_GetFullscreenDesc,
    .GetHwnd = bridge_swapchain_GetHwnd,
    .GetCoreWindow = bridge_swapchain_GetCoreWindow,
    .Present1 = bridge_swapchain_Present1,
    .IsTemporaryMonoSupported = bridge_swapchain_IsTemporaryMonoSupported,
    .GetRestrictToOutput = bridge_swapchain_GetRestrictToOutput,
    .SetBackgroundColor = bridge_swapchain_SetBackgroundColor,
    .GetBackgroundColor = bridge_swapchain_GetBackgroundColor,
    .SetRotation = bridge_swapchain_SetRotation,
    .GetRotation = bridge_swapchain_GetRotation,
    .SetSourceSize = bridge_swapchain_SetSourceSize,
    .GetSourceSize = bridge_swapchain_GetSourceSize,
    .SetMaximumFrameLatency = bridge_swapchain_SetMaximumFrameLatency,
    .GetMaximumFrameLatency = bridge_swapchain_GetMaximumFrameLatency,
    .GetFrameLatencyWaitableObject = bridge_swapchain_GetFrameLatencyWaitableObject,
    .SetMatrixTransform = bridge_swapchain_SetMatrixTransform,
    .GetMatrixTransform = bridge_swapchain_GetMatrixTransform,
    .GetCurrentBackBufferIndex = bridge_swapchain_GetCurrentBackBufferIndex,
    .CheckColorSpaceSupport = bridge_swapchain_CheckColorSpaceSupport,
    .SetColorSpace1 = bridge_swapchain_SetColorSpace1,
    .ResizeBuffers1 = bridge_swapchain_ResizeBuffers1,
    .SetHDRMetaData = bridge_swapchain_SetHDRMetaData,
};

static HRESULT bridge_create_swapchain(IDXGIFactory2 *factory, IDXGIVkSwapChainFactory *vk_factory,
        HWND hwnd, const DXGI_SWAP_CHAIN_DESC1 *desc_in, const DXGI_SWAP_CHAIN_FULLSCREEN_DESC *fullscreen_desc,
        IDXGISwapChain1 **swapchain)
{
    struct bridge_surface_factory *surface_factory;
    struct bridge_swapchain *chain;
    DXGI_SWAP_CHAIN_DESC1 desc;
    HRESULT hr;

    if (!hwnd || !desc_in || !swapchain)
        return DXGI_ERROR_INVALID_CALL;
    *swapchain = NULL;

    desc = *desc_in;
    bridge_window_size(hwnd, &desc.Width, &desc.Height);

    if (!(surface_factory = calloc(1, sizeof(*surface_factory))))
        return E_OUTOFMEMORY;
    surface_factory->IDXGIVkSurfaceFactory_iface.lpVtbl = &bridge_surface_factory_vtbl;
    surface_factory->refcount = 1;
    surface_factory->hwnd = hwnd;

    if (!(chain = calloc(1, sizeof(*chain))))
    {
        free(surface_factory);
        return E_OUTOFMEMORY;
    }

    if (FAILED(hr = IDXGIVkSwapChainFactory_CreateSwapChain(vk_factory,
            &surface_factory->IDXGIVkSurfaceFactory_iface, &desc, &chain->presenter)))
    {
        ERR("dxgi bridge: IDXGIVkSwapChainFactory::CreateSwapChain failed, hr %#x.\n", hr);
        IDXGIVkSurfaceFactory_Release(&surface_factory->IDXGIVkSurfaceFactory_iface);
        free(chain);
        return hr;
    }

    chain->IDXGISwapChain4_iface.lpVtbl = &bridge_swapchain_vtbl;
    chain->refcount = 1;
    chain->surface_factory = &surface_factory->IDXGIVkSurfaceFactory_iface;
    chain->factory = factory;
    IDXGIFactory2_AddRef(factory);
    chain->hwnd = hwnd;
    if (FAILED(IDXGIVkSwapChain_QueryInterface(chain->presenter, &IID_IDXGIVkSwapChain1, (void **)&chain->presenter1)))
        chain->presenter1 = NULL;

    if (fullscreen_desc)
    {
        chain->fullscreen_desc = *fullscreen_desc;
    }
    else
    {
        chain->fullscreen_desc.ScanlineOrdering = DXGI_MODE_SCANLINE_ORDER_UNSPECIFIED;
        chain->fullscreen_desc.Scaling = DXGI_MODE_SCALING_UNSPECIFIED;
        chain->fullscreen_desc.Windowed = TRUE;
    }
    chain->fullscreen = !chain->fullscreen_desc.Windowed;

    WARN("dxgi bridge: D3D12 swapchain %p on hwnd %p, %ux%u, format %#x, %u buffers.\n",
            chain, hwnd, desc.Width, desc.Height, desc.Format, desc.BufferCount);

    *swapchain = (IDXGISwapChain1 *)&chain->IDXGISwapChain4_iface;
    return S_OK;
}

/* ------------------------------------------------------------------------- */
/* Factory vtable hooks                                                       */
/* ------------------------------------------------------------------------- */

typedef HRESULT (STDMETHODCALLTYPE *factory_create_swapchain_fn)(IDXGIFactory2 *,
        IUnknown *, DXGI_SWAP_CHAIN_DESC *, IDXGISwapChain **);
typedef HRESULT (STDMETHODCALLTYPE *factory_create_swapchain_for_hwnd_fn)(IDXGIFactory2 *,
        IUnknown *, HWND, const DXGI_SWAP_CHAIN_DESC1 *, const DXGI_SWAP_CHAIN_FULLSCREEN_DESC *,
        IDXGIOutput *, IDXGISwapChain1 **);

static factory_create_swapchain_fn original_CreateSwapChain;
static factory_create_swapchain_for_hwnd_fn original_CreateSwapChainForHwnd;

static HRESULT STDMETHODCALLTYPE bridge_factory_CreateSwapChainForHwnd(IDXGIFactory2 *factory,
        IUnknown *device, HWND hwnd, const DXGI_SWAP_CHAIN_DESC1 *desc,
        const DXGI_SWAP_CHAIN_FULLSCREEN_DESC *fullscreen_desc, IDXGIOutput *restrict_to_output,
        IDXGISwapChain1 **swapchain)
{
    IDXGIVkSwapChainFactory *vk_factory;
    HRESULT hr;

    hr = original_CreateSwapChainForHwnd(factory, device, hwnd, desc, fullscreen_desc, restrict_to_output, swapchain);
    if (SUCCEEDED(hr) || !device)
        return hr;

    if (FAILED(IUnknown_QueryInterface(device, &IID_IDXGIVkSwapChainFactory, (void **)&vk_factory)))
        return hr;

    WARN("dxgi bridge: dxgi.dll refused a D3D12 queue (hr %#x); creating the swapchain here.\n", hr);
    hr = bridge_create_swapchain(factory, vk_factory, hwnd, desc, fullscreen_desc, swapchain);
    IDXGIVkSwapChainFactory_Release(vk_factory);
    return hr;
}

static HRESULT STDMETHODCALLTYPE bridge_factory_CreateSwapChain(IDXGIFactory2 *factory,
        IUnknown *device, DXGI_SWAP_CHAIN_DESC *desc, IDXGISwapChain **swapchain)
{
    DXGI_SWAP_CHAIN_FULLSCREEN_DESC fullscreen_desc;
    IDXGIVkSwapChainFactory *vk_factory;
    DXGI_SWAP_CHAIN_DESC1 desc1;
    HRESULT hr;

    hr = original_CreateSwapChain(factory, device, desc, swapchain);
    if (SUCCEEDED(hr) || !device || !desc)
        return hr;

    if (FAILED(IUnknown_QueryInterface(device, &IID_IDXGIVkSwapChainFactory, (void **)&vk_factory)))
        return hr;

    memset(&desc1, 0, sizeof(desc1));
    desc1.Width = desc->BufferDesc.Width;
    desc1.Height = desc->BufferDesc.Height;
    desc1.Format = desc->BufferDesc.Format;
    desc1.Stereo = FALSE;
    desc1.SampleDesc = desc->SampleDesc;
    desc1.BufferUsage = desc->BufferUsage;
    desc1.BufferCount = desc->BufferCount;
    desc1.Scaling = DXGI_SCALING_STRETCH;
    desc1.SwapEffect = desc->SwapEffect;
    desc1.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    desc1.Flags = desc->Flags;

    fullscreen_desc.RefreshRate = desc->BufferDesc.RefreshRate;
    fullscreen_desc.ScanlineOrdering = desc->BufferDesc.ScanlineOrdering;
    fullscreen_desc.Scaling = desc->BufferDesc.Scaling;
    fullscreen_desc.Windowed = desc->Windowed;

    WARN("dxgi bridge: dxgi.dll refused a D3D12 queue in CreateSwapChain (hr %#x); creating it here.\n", hr);
    hr = bridge_create_swapchain(factory, vk_factory, desc->OutputWindow, &desc1, &fullscreen_desc,
            (IDXGISwapChain1 **)swapchain);
    IDXGIVkSwapChainFactory_Release(vk_factory);
    return hr;
}

void d3d12core_dxgi_bridge_install(IDXGIAdapter *adapter)
{
    static SRWLOCK lock = SRWLOCK_INIT;
    IDXGIFactory2 *factory = NULL;
    IDXGIFactory2Vtbl *vtbl;
    const char *env;
    DWORD old_protect;

    if ((env = getenv("VKD3D_DXGI_BRIDGE")) && env[0] == '0')
        return;

    if (!adapter || FAILED(IDXGIAdapter_GetParent(adapter, &IID_IDXGIFactory2, (void **)&factory)))
    {
        /* CreateDXGIFactory1 on purpose: d3d12core.dll already imports it, so
         * this adds no new import that a dxgi.dll might lack. */
        if (FAILED(CreateDXGIFactory1(&IID_IDXGIFactory2, (void **)&factory)))
        {
            WARN("dxgi bridge: no IDXGIFactory2 to hook.\n");
            return;
        }
    }

    AcquireSRWLockExclusive(&lock);
    vtbl = (IDXGIFactory2Vtbl *)factory->lpVtbl;
    if (vtbl->CreateSwapChainForHwnd != bridge_factory_CreateSwapChainForHwnd)
    {
        if (VirtualProtect(vtbl, sizeof(*vtbl), PAGE_READWRITE, &old_protect))
        {
            /* One set of originals: a process has one dxgi.dll, hence one
             * factory class. A second, different vtable would be unusual; keep
             * the first originals rather than chain to our own hooks. */
            if (!original_CreateSwapChainForHwnd)
            {
                original_CreateSwapChain = vtbl->CreateSwapChain;
                original_CreateSwapChainForHwnd = vtbl->CreateSwapChainForHwnd;
                vtbl->CreateSwapChain = bridge_factory_CreateSwapChain;
                vtbl->CreateSwapChainForHwnd = bridge_factory_CreateSwapChainForHwnd;
                WARN("dxgi bridge: hooked factory vtable %p (DXGI swapchains for D3D12 queues).\n", vtbl);
            }
            VirtualProtect(vtbl, sizeof(*vtbl), old_protect, &old_protect);
        }
        else
        {
            ERR("dxgi bridge: VirtualProtect on factory vtable %p failed, error %lu.\n", vtbl, GetLastError());
        }
    }
    ReleaseSRWLockExclusive(&lock);

    IDXGIFactory2_Release(factory);
}
