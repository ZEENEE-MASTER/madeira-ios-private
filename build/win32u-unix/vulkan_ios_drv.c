/* iOS Vulkan surface driver for win32u (the pVulkanInit user-driver slot).
 *
 * Modelled on dlls/winemac.drv/vulkan.c, with the Cocoa view replaced by the
 * CAMetalLayer that app/Madeira/IOSDisplayShim.m already hands DXMT for any
 * HWND: game mode resolves every window to the single fullscreen layer, desktop
 * mode to that window's layer in the Winios compositor. Using the same shim
 * means DXMT (D3D11) and MoltenVK (D3D12 via vkd3d-proton) present into the same
 * place, and a title uses one or the other, never both at once.
 *
 * win32u calls p_vulkan_surface_create from vkCreateWin32SurfaceKHR; the
 * surface we return is a VK_EXT_metal_surface on that layer. MoltenVK then owns
 * the layer's drawables for the swapchain's lifetime.
 *
 * Registered in driver_ios.c (winios_user_driver.pVulkanInit). Only reached when
 * win32u's vulkan_init_once found a Vulkan implementation, i.e. when the app
 * was built with MoltenVK (MADEIRA_MOLTENVK); otherwise inert.
 */

#if 0
#pragma makedep unix
#endif

#include "config.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "ntstatus.h"
#include "win32u_private.h"
#include "ntuser_private.h"

WINE_DEFAULT_DEBUG_CHANNEL(vulkan);

/* app/Madeira/IOSDisplayShim.m. Declared with void * so no Obj-C types leak
 * into Wine's headers; the shim's own types are opaque pointer typedefs. The
 * "view" argument carries the HWND through (see my_get_win_data there). The
 * returned metal view is a +1 retained CAMetalLayer. */
extern void *macdrv_view_create_metal_view( void *view, void *device );
extern void *macdrv_view_get_metal_layer( void *metal_view );
extern void macdrv_view_release_metal_view( void *metal_view );

struct ios_vk_surface
{
    struct client_surface client;
    void *metal_view;
};

static struct ios_vk_surface *impl_from_client_surface( struct client_surface *client )
{
    return CONTAINING_RECORD( client, struct ios_vk_surface, client );
}

static void ios_vk_surface_destroy( struct client_surface *client )
{
    struct ios_vk_surface *surface = impl_from_client_surface( client );

    TRACE( "%s\n", debugstr_client_surface( client ) );
    if (surface->metal_view) macdrv_view_release_metal_view( surface->metal_view );
    surface->metal_view = NULL;
}

/* The layer is owned by the app's view hierarchy, not by the HWND, so there is
 * nothing to detach, move or blit: MoltenVK presents straight into it. */
static void ios_vk_surface_detach( struct client_surface *client )
{
    TRACE( "%s\n", debugstr_client_surface( client ) );
}

static void ios_vk_surface_update( struct client_surface *client )
{
}

static void ios_vk_surface_present( struct client_surface *client, HDC hdc )
{
}

static const struct client_surface_funcs ios_vk_surface_funcs =
{
    .destroy = ios_vk_surface_destroy,
    .detach = ios_vk_surface_detach,
    .update = ios_vk_surface_update,
    .present = ios_vk_surface_present,
};

static VkResult ios_vulkan_surface_create( HWND hwnd, const struct vulkan_instance *instance,
                                           VkSurfaceKHR *handle, struct client_surface **client )
{
    VkMetalSurfaceCreateInfoEXT create_info;
    struct ios_vk_surface *surface;
    VkResult res;

    TRACE( "hwnd %p, instance %p, handle %p, client %p\n", hwnd, instance, handle, client );

    if (!instance->p_vkCreateMetalSurfaceEXT)
    {
        ERR( "MoltenVK instance lacks vkCreateMetalSurfaceEXT\n" );
        return VK_ERROR_EXTENSION_NOT_PRESENT;
    }

    if (!(surface = client_surface_create( sizeof(*surface), &ios_vk_surface_funcs, hwnd )))
        return VK_ERROR_OUT_OF_HOST_MEMORY;

    if (!(surface->metal_view = macdrv_view_create_metal_view( (void *)hwnd, (void *)(UINT_PTR)1 )))
    {
        ERR( "no CAMetalLayer for hwnd %p (display layer not registered yet?)\n", hwnd );
        client_surface_release( &surface->client );
        return VK_ERROR_INITIALIZATION_FAILED;
    }

    memset( &create_info, 0, sizeof(create_info) );
    create_info.sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT;
    create_info.pLayer = macdrv_view_get_metal_layer( surface->metal_view );

    res = instance->p_vkCreateMetalSurfaceEXT( instance->host.instance, &create_info, NULL /* allocator */, handle );
    if (res != VK_SUCCESS)
    {
        ERR( "vkCreateMetalSurfaceEXT failed, res=%d\n", res );
        client_surface_release( &surface->client );
        return res;
    }

    *client = &surface->client;
    dprintf( 2, "[vulkan-ios] metal surface 0x%s for hwnd %p layer %p\n",
             wine_dbgstr_longlong( *handle ), hwnd, create_info.pLayer );
    return VK_SUCCESS;
}

static VkBool32 ios_get_physical_device_presentation_support( struct vulkan_physical_device *physical_device,
                                                              uint32_t index )
{
    return VK_TRUE;
}

/* Guest asks for VK_KHR_win32_surface; the host needs VK_EXT_metal_surface. */
static void ios_map_instance_extensions( struct vulkan_instance_extensions *extensions )
{
    if (extensions->has_VK_KHR_win32_surface) extensions->has_VK_EXT_metal_surface = 1;
    if (extensions->has_VK_EXT_metal_surface) extensions->has_VK_KHR_win32_surface = 1;
}

static void ios_map_device_extensions( struct vulkan_device_extensions *extensions )
{
}

static const struct vulkan_driver_funcs ios_vulkan_driver_funcs =
{
    .p_vulkan_surface_create = ios_vulkan_surface_create,
    .p_get_physical_device_presentation_support = ios_get_physical_device_presentation_support,
    .p_map_instance_extensions = ios_map_instance_extensions,
    .p_map_device_extensions = ios_map_device_extensions,
};

UINT winios_VulkanInit( UINT version, void *vulkan_handle, const struct vulkan_driver_funcs **driver_funcs )
{
    if (version != WINE_VULKAN_DRIVER_VERSION)
    {
        ERR( "version mismatch, win32u wants %u but driver has %u\n", version, WINE_VULKAN_DRIVER_VERSION );
        return STATUS_INVALID_PARAMETER;
    }

    *driver_funcs = &ios_vulkan_driver_funcs;
    return STATUS_SUCCESS;
}
