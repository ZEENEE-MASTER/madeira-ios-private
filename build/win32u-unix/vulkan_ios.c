/* iOS override for dlls/win32u/vulkan.c.
 *
 * win32u reaches the host Vulkan implementation with
 *
 *     vulkan_handle = dlopen( SONAME_LIBVULKAN, RTLD_NOW );
 *     p_vkGetDeviceProcAddr   = dlsym( vulkan_handle, "vkGetDeviceProcAddr" );
 *     p_vkGetInstanceProcAddr = dlsym( vulkan_handle, "vkGetInstanceProcAddr" );
 *
 * and fetches every other entry point through those two. On iOS there is no
 * Vulkan loader and nothing to dlopen: MoltenVK is linked statically into
 * Madeira.app (libMoltenVK.a, -force_load). So, exactly as freetype_ios.c does
 * for freetype, dlopen/dlsym/dlclose are rewritten to a two-entry symbol table
 * resolved by the static linker.
 *
 * MADEIRA_MOLTENVK is set by build.sh only when libMoltenVK.a is present. Without
 * it SONAME_LIBVULKAN stays undefined (config_ios.h), vulkan_init_once logs
 * "built without Vulkan support" and nothing references MoltenVK -- the app still
 * links, and D3D11 through DXMT is unaffected either way.
 *
 * With it, the chain for a D3D12 title is
 *   d3d12core.dll (vkd3d-proton) -> vulkan-1.dll -> winevulkan.dll (PE)
 *   -> winevulkan unixlib (libntdll_unix.a) -> this file -> MoltenVK -> Metal
 * and window surfaces come from vulkan_ios_drv.c.
 */

#ifdef MADEIRA_MOLTENVK
#define SONAME_LIBVULKAN "libMoltenVK.a"
#endif

/* Rewrites apply to <dlfcn.h>'s prototypes too, which is why the shims are
 * non-static and match dlfcn.h's signatures exactly (see freetype_ios.c). */
#define dlopen  ios_vk_dlopen
#define dlsym   ios_vk_dlsym
#define dlclose ios_vk_dlclose

#include "vulkan.c"

#undef dlopen
#undef dlsym
#undef dlclose

#ifdef MADEIRA_MOLTENVK
/* Bound by assembly name so no Vulkan prototype is needed here: Wine's
 * wine/vulkan.h is built with VK_NO_PROTOTYPES, and MoltenVK's own headers
 * would clash with it. MoltenVK exports both (MVK_PUBLIC_VULKAN_SYMBOL). */
extern void *ios_mvk_GetInstanceProcAddr( void *instance, const char *name ) __asm__("_vkGetInstanceProcAddr");
extern void *ios_mvk_GetDeviceProcAddr( void *device, const char *name ) __asm__("_vkGetDeviceProcAddr");
#endif

static int ios_vk_sentinel;

void *ios_vk_dlopen( const char *path, int mode )
{
    (void)mode;
#ifdef MADEIRA_MOLTENVK
    if (path && strstr( path, "MoltenVK" ))
    {
        TRACE( "iOS: %s -> statically linked MoltenVK\n", path );
        return &ios_vk_sentinel;
    }
#endif
    WARN( "iOS: no Vulkan library for %s\n", path ? path : "(null)" );
    return NULL;
}

int ios_vk_dlclose( void *handle )
{
    (void)handle;
    return 0;
}

void *ios_vk_dlsym( void *handle, const char *symbol )
{
    if (handle != &ios_vk_sentinel || !symbol) return NULL;
#ifdef MADEIRA_MOLTENVK
    if (!strcmp( symbol, "vkGetInstanceProcAddr" )) return (void *)ios_mvk_GetInstanceProcAddr;
    if (!strcmp( symbol, "vkGetDeviceProcAddr" )) return (void *)ios_mvk_GetDeviceProcAddr;
    /* Anything else a future win32u asks for by name: global-level commands
     * are what vkGetInstanceProcAddr(NULL, name) resolves. */
    return ios_mvk_GetInstanceProcAddr( NULL, symbol );
#else
    return NULL;
#endif
}
