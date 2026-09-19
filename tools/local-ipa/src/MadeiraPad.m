// MadeiraPad.dylib — injected into the CI-built Madeira.app (LC_LOAD_DYLIB), built
// on Windows with clang + the iPhoneOS SDK, the same way as the CP2077 port.
//
// 1. Controllers -> XInput. Fills the "MPAD" block that the Madeira xinput DLLs
//    read (layout documented in xinput.c / Gamepad.swift), publishes its address
//    as MADEIRA_PAD_SHM before Wine starts, and plays game rumble on controller
//    haptics.
// 2. Launch defaults. Persistent shader caches and MoltenVK/vkd3d settings, set
//    with overwrite=0 so the app's own buttons and Documents/*.txt switches win.
// 3. Launch override. If Documents/madeira-launch.txt exists, its first line
//    replaces MADEIRA_EXE and its second line MADEIRA_ARGS whenever the app sets
//    them (e.g. the Stray or Thumper button), so any game can be started — with
//    its own arguments — without a new app build.

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <sys/mman.h>
#include <stdarg.h>
#include <mach-o/dyld.h>

#pragma mark - own log

// Everything this dylib decides happens in its constructor, before the app
// redirects stderr into madeira-log.txt, so those lines never reached the log.
// They go to Documents/madeira-pad-log.txt as well (rewritten every launch).
static FILE *g_padlog;

static void pad_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void pad_log(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    if (g_padlog) {
        va_start(ap, fmt);
        vfprintf(g_padlog, fmt, ap);
        va_end(ap);
        fflush(g_padlog);
    }
}

/// Free gaps (>= 16 MB) in the low host range, where the JIT pool and every
/// fixed-base image have to fit, plus the large mappings between them.
static void dump_vm_map(const char *when)
{
    vm_address_t addr = 0x100000000ULL, prev_end = 0x100000000ULL;
    unsigned long long free_total = 0;
    pad_log("[madeira-pad] vm map (%s), 0x100000000..0x7000000000:\n", when);
    for (int n = 0; n < 4096; n++) {
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        vm_address_t a = addr;
        if (vm_region_64(mach_task_self(), &a, &size, VM_REGION_BASIC_INFO_64,
                         (vm_region_info_t)&info, &count, &object) != KERN_SUCCESS)
            a = 0x7000000000ULL, size = 0;
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
        if (a > 0x7000000000ULL) a = 0x7000000000ULL;
        if (a > prev_end && a - prev_end >= (16ULL << 20)) {
            pad_log("[madeira-pad]   FREE 0x%llx..0x%llx %6llu MB\n", (unsigned long long)prev_end,
                    (unsigned long long)a, (unsigned long long)(a - prev_end) >> 20);
            free_total += a - prev_end;
        }
        if (a >= 0x7000000000ULL) break;
        if (size >= (64ULL << 20))
            pad_log("[madeira-pad]   used 0x%llx..0x%llx %6llu MB prot=%d/%d\n", (unsigned long long)a,
                    (unsigned long long)(a + size), (unsigned long long)size >> 20, info.protection, info.max_protection);
        prev_end = a + size;
        addr = a + size;
    }
    pad_log("[madeira-pad]   %llu MB free in gaps of 16 MB or more\n", free_total >> 20);
}

#pragma mark - log archive

// The app keeps only madeira-log.txt and madeira-log.prev.txt, and every launch
// is two processes (the StikDebug JIT request, then the real run), so .prev is
// always the tiny JIT-request stub and each real run is lost at the next launch.
// This runs before the app rotates the log: a real run's log (it contains the
// Wine sequence) is copied to Documents/madeira-logs/<time>-<game>.txt, together
// with that run's madeira-pad-log.txt. The newest 15 are kept.
static NSString *log_titles(NSString *path)
{
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData *d = [h readDataOfLength:8u << 20];
    [h closeFile];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]
               ?: [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    if (!s) return nil;
    static NSSet *system;
    if (!system) system = [NSSet setWithArray:@[ @"explorer", @"services", @"rpcss", @"winedevice", @"plugplay",
                                                  @"svchost", @"conhost", @"rundll32", @"start", @"cmd", @"wineboot",
                                                  @"tabtip", @"steamwebhelper", @"crashreport", @"installermessage" ]];
    NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"(?:Target exe: |spawn:L\"|image=L\")[^\\n]*?([A-Za-z0-9 _.+-]+)\\.exe" options:NSRegularExpressionCaseInsensitive error:nil];
    for (NSTextCheckingResult *m in [re matchesInString:s options:0 range:NSMakeRange(0, s.length)]) {
        NSString *n = [s substringWithRange:[m rangeAtIndex:1]];
        NSString *key = n.lowercaseString;
        if ([system containsObject:key] || [key hasSuffix:@"crashreport"]) continue;
        [names addObject:[[n stringByReplacingOccurrencesOfString:@" " withString:@"_"] substringToIndex:MIN(n.length, 40u)]];
        if (names.count >= 3) break;
    }
    if ([s rangeOfString:@"Running full Wine sequence"].location == NSNotFound) return nil;   // JIT-request stub
    return names.count ? [names.array componentsJoinedByString:@"+"] : @"wine";
}

static void archive_previous_log(NSString *docs)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *log = [docs stringByAppendingPathComponent:@"madeira-log.txt"];
    NSDictionary *attr = [fm attributesOfItemAtPath:log error:nil];
    if (!attr || attr.fileSize < 32 * 1024) return;
    NSString *titles = log_titles(log);
    if (!titles) return;
    NSString *dir = [docs stringByAppendingPathComponent:@"madeira-logs"];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSString *stem = [NSString stringWithFormat:@"%@-%@", [f stringFromDate:attr.fileModificationDate], titles];
    NSString *dest = [dir stringByAppendingPathComponent:[stem stringByAppendingString:@".txt"]];
    if ([fm fileExistsAtPath:dest]) return;
    [fm copyItemAtPath:log toPath:dest error:nil];
    NSString *pad = [docs stringByAppendingPathComponent:@"madeira-pad-log.txt"];
    if ([fm fileExistsAtPath:pad])
        [fm copyItemAtPath:pad toPath:[dir stringByAppendingPathComponent:[stem stringByAppendingString:@".pad.txt"]] error:nil];

    NSArray *all = [[fm contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *logs = [NSMutableArray array];
    for (NSString *n in all) if (![n hasSuffix:@".pad.txt"]) [logs addObject:n];
    for (NSUInteger i = 0; i + 15 < logs.count; i++) {
        NSString *n = logs[i];
        [fm removeItemAtPath:[dir stringByAppendingPathComponent:n] error:nil];
        [fm removeItemAtPath:[dir stringByAppendingPathComponent:
            [[n stringByDeletingPathExtension] stringByAppendingString:@".pad.txt"]] error:nil];
    }
}

#define SLOTS 4
#define SLOT_SIZE 32
#define HEADER 16

static uint8_t *g_block;
static GCController *g_pads[SLOTS];
static uint32_t g_packets[SLOTS];
static uint32_t g_last_rumble[SLOTS];
static id g_rumble[SLOTS];          // MPRumble
static dispatch_queue_t g_queue;

#pragma mark - image base vs JIT pool

// The problem this solves
// -----------------------
// A Windows executable built with relocations stripped can ONLY be mapped at
// its preferred base. Unreal shipping binaries use 0x140000000; protected ones
// (Stellar Blade's SB-Win64-Shipping.exe, 314 MB) have no .reloc at all. When
// something else owns that address Wine dies with
//   wine: failed to create main module ... status c0000018
// (ntdll perform_relocations: "no relocation records" = CONFLICTING_ADDRESSES).
//
// On this device the only usable free span is roughly
//   0x11a000000 .. 0x158000000     (~1 GB; above it iOS's own mappings run
//                                    until the forbidden 0x70_0000_0000 window)
// and the JIT pool must start above 0x119000000 (FEX emit bug below that). So a
// 896 MB pool ALWAYS covers 0x140000000, and simply reserving the game's band
// leaves no 896 MB hole at all — the kernel then hands back 0x7000000000, which
// the app rejects ("BAD POOL placement ... Killing in 10s"). That is the crash
// this build fixes.
//
// The only arrangement that satisfies everyone is a SMALLER pool that ends
// below the image base:
//   [pool: ~0x11b000000 .. <0x140000000]  [image: 0x140000000 .. +SizeOfImage]
// so this code, when (and only when) the launch target is a relocation-stripped
// executable:
//   1. reads its PE header for ImageBase / SizeOfImage,
//   2. probes where the kernel is currently allocating,
//   3. writes Documents/madeira-pool.txt with the largest 64 MB-aligned pool
//      that still ends below ImageBase (the app already honours that file),
//   4. reserves the image band so the pool cannot creep into it, releasing it
//      once the pool address is published and before Wine maps anything.
// Anything else (desktop, Steam, Stray, Thumper) runs with the stock 896 MB
// pool and no reservation.
//
// Documents/madeira-imagebase.txt overrides: "<hex base> <MB>", or "0" to
// disable the whole mechanism.

#define FEX_POOL_FLOOR   0x119000000ULL   // StikJITHelper's low bound
#define POOL_GRAIN       (16ULL << 20)   // finer: every MB of pool is FEX headroom
#define POOL_MIN_MB      256
#define POOL_MAX_MB      896

static vm_address_t g_hold_base;
static vm_size_t g_hold_size;
static BOOL g_hold_active;
static BOOL g_hold_disabled;
static unsigned long long g_pool_mb = 896;
static unsigned long long g_pool_rx;              // WINE_IOS_JIT_RX, once the pool exists

static void hold_image_band(void)
{
    if (!g_hold_size) return;
    vm_address_t addr = g_hold_base;
    // mach_vm_* is not declared in the iOS SDK; vm_* is, and on arm64 its
    // addresses are already 64-bit.
    kern_return_t kr = vm_allocate(mach_task_self(), &addr, g_hold_size, VM_FLAGS_FIXED);
    if (kr != KERN_SUCCESS || addr != g_hold_base) {
        if (kr == KERN_SUCCESS) vm_deallocate(mach_task_self(), addr, g_hold_size);
        pad_log("[madeira-pad] image band 0x%llx+%lluMB NOT reserved (kr=%d)\n",
                (unsigned long long)g_hold_base, (unsigned long long)(g_hold_size >> 20), kr);
        return;
    }
    vm_protect(mach_task_self(), addr, g_hold_size, FALSE, VM_PROT_NONE);
    g_hold_active = YES;
    pad_log("[madeira-pad] image band reserved 0x%llx..0x%llx\n",
            (unsigned long long)g_hold_base, (unsigned long long)(g_hold_base + g_hold_size));
}

static void release_image_band(const char *why)
{
    if (!g_hold_active) return;
    vm_deallocate(mach_task_self(), g_hold_base, g_hold_size);
    g_hold_active = NO;
    pad_log("[madeira-pad] image band released (%s)\n", why ? why : "?");
}

/// Where is the kernel handing out memory right now? Allocate and immediately
/// free a probe: the JIT pool lands just above this, after the app's pin chunks.
static unsigned long long probe_frontier(void)
{
    vm_address_t addr = 0;
    if (vm_allocate(mach_task_self(), &addr, 16 << 20, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) return 0;
    vm_deallocate(mach_task_self(), addr, 16 << 20);
    return (unsigned long long)addr;
}

/// ImageBase / SizeOfImage / relocations-stripped from a PE file, or 0.
static BOOL read_pe_layout(NSString *unixPath, unsigned long long *base, unsigned long long *size, BOOL *stripped)
{
    NSData *d = [NSData dataWithContentsOfFile:unixPath options:NSDataReadingMappedIfSafe error:nil];
    if (d.length < 0x400) return NO;
    const uint8_t *b = d.bytes;
    if (b[0] != 'M' || b[1] != 'Z') return NO;
    uint32_t pe;
    memcpy(&pe, b + 0x3c, 4);
    if (pe + 0x100 > d.length) return NO;
    uint32_t sig;
    memcpy(&sig, b + pe, 4);
    if (sig != 0x00004550) return NO;
    uint16_t chars, magic;
    memcpy(&chars, b + pe + 22, 2);
    memcpy(&magic, b + pe + 24, 2);
    if (magic != 0x20b) return NO;                     // PE32+ only
    memcpy(base, b + pe + 24 + 24, 8);
    uint32_t sz;
    memcpy(&sz, b + pe + 24 + 56, 4);
    *size = sz;
    *stripped = (chars & 0x0001) != 0;                 // IMAGE_FILE_RELOCS_STRIPPED
    return YES;
}

/// C:\... -> <Documents>/wine/drive_c/...
static NSString *windows_to_unix(NSString *docs, NSString *win)
{
    if (win.length < 3 || ![[win substringWithRange:NSMakeRange(1, 2)] isEqualToString:@":\\"]) return nil;
    NSString *rest = [[win substringFromIndex:3] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    return [docs stringByAppendingPathComponent:[@"wine/drive_c/" stringByAppendingString:rest]];
}

/// Sizes the JIT pool so it ends below `image_base`, and reserves the band.
/// The marker file records that madeira-pool.txt is ours to manage.
static void plan_for_fixed_base_image(NSString *docs, NSString *winExe)
{
    NSString *poolFile = [docs stringByAppendingPathComponent:@"madeira-pool.txt"];
    NSString *marker = [docs stringByAppendingPathComponent:@".madeira-pad-pool"];
    NSFileManager *fm = NSFileManager.defaultManager;

    NSString *unixExe = winExe ? windows_to_unix(docs, winExe) : nil;
    unsigned long long base = 0, size = 0;
    BOOL stripped = NO;
    BOOL needs_fixed_base = unixExe && read_pe_layout(unixExe, &base, &size, &stripped) && stripped && base && size;

    if (!needs_fixed_base || g_hold_disabled) {
        // Hand the stock 896 MB pool back if we were the one who shrank it.
        if ([fm fileExistsAtPath:marker]) {
            [fm removeItemAtPath:poolFile error:nil];
            [fm removeItemAtPath:marker error:nil];
            pad_log("[madeira-pad] restored the default JIT pool (no fixed-base target)\n");
        }
        if (needs_fixed_base && g_hold_disabled)
            pad_log("[madeira-pad] fixed-base handling disabled by madeira-imagebase.txt\n");
        return;
    }

    if (!g_hold_base) {
        g_hold_base = (vm_address_t)base;
        g_hold_size = (vm_size_t)((size + POOL_GRAIN - 1) & ~(POOL_GRAIN - 1));
    }

    unsigned long long frontier = probe_frontier();
    unsigned long long pool_start = frontier > FEX_POOL_FLOOR ? frontier : FEX_POOL_FLOOR;
    // The pool lands somewhere above the frontier once StikJITHelper's pin
    // chunks and the app's own allocations have run: measured +16 MB and
    // +55 MB on two launches, so budget 64 MB. A further 32 MB of slack keeps
    // the pool clear of the image base even at the worst placement.
    pool_start += 64ULL << 20;
    unsigned long long room = g_hold_base > pool_start + (32ULL << 20)
                            ? g_hold_base - pool_start - (32ULL << 20) : 0;
    unsigned long long mb = (room / POOL_GRAIN) * (POOL_GRAIN >> 20);
    if (mb > POOL_MAX_MB) mb = POOL_MAX_MB;
    // The image copy alone is SizeOfImage; what is left is the budget for the
    // Windows DLL copies and FEX's translated code.
    unsigned long long image_mb = size >> 20;

    pad_log("[madeira-pad] %s: ImageBase=0x%llx size=%lluMB relocs-stripped -> must load fixed\n",
            winExe.lastPathComponent.UTF8String, base, size >> 20);
    pad_log("[madeira-pad]   allocator frontier 0x%llx, room below image 0x%llx = %lluMB\n",
            frontier, room, room >> 20);

    if (mb < POOL_MIN_MB) {
        pad_log("[madeira-pad]   too little room for a usable pool — leaving everything stock; "
                        "this title cannot load in this layout\n");
        g_hold_size = 0;
        if ([fm fileExistsAtPath:marker]) {
            [fm removeItemAtPath:poolFile error:nil];
            [fm removeItemAtPath:marker error:nil];
        }
        return;
    }

    NSString *existing = [NSString stringWithContentsOfFile:poolFile encoding:NSUTF8StringEncoding error:nil];
    BOOL ours = [fm fileExistsAtPath:marker];
    if (existing.length && !ours) {
        pad_log("[madeira-pad]   keeping your madeira-pool.txt (%s MB)\n",
                [existing stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].UTF8String);
    } else {
        NSString *value = [NSString stringWithFormat:@"%llu\n", mb];
        [value writeToFile:poolFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"written by MadeiraPad.dylib\n" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
        pad_log("[madeira-pad]   JIT pool set to %lluMB so it ends below the image base "
                        "(%lluMB image copy + ~70MB Windows DLLs leaves ~%lldMB for translated code)\n",
                mb, image_mb, (long long)mb - (long long)image_mb - 70);
        g_pool_mb = mb;
    }
    hold_image_band();
}

#pragma mark - ARM64EC data coherence

// Madeira runs every ARM64EC DLL from a copy inside the JIT pool: the whole
// image is memcpy'd there (virtual_ios.c, "preserves ADRP-based PC-relative
// references"), so the DLL's own code reads and writes the COPY's .data. The
// original image stays mapped as well, and that is the address the export
// table hands to x64 importers. The two are synced one way only (image ->
// copy, at load), so data a DLL initialises itself never becomes visible to
// x64 code that imports it.
//
// TEKKEN 8 died on exactly that. Wine's msvcp140 constructs std::cout in its
// DllMain (init_io) — in the pool copy — and one of the game's first static
// initializers does `std::cout.iword(std::ios_base::xalloc())`: it read the
// ORIGINAL cout's vbtable pointer, still 0, and faulted at address 0x4. Any
// x64 program touching cout/cerr/clog/cin, or msvcrt's _iob/_fmode/_environ,
// is exposed the same way.
//
// Fix: right after the copy (Madeira calls sys_icache_invalidate on it),
// remap the original image's writable sections onto the copy's pages, so the
// two addresses are one piece of memory. ARM64EC images only (they carry a
// .hexpthk section): an x64 image's pool copy holds pool-relocated pointers
// that x64 code must never see, so those stay separate.
// Documents/madeira-ecdata.txt: module-name prefixes to cover (default
// "msvcp msvcr"), "all" for every ARM64EC DLL, or "0" to turn this off.

static unsigned long long g_pool_rw, g_pool_size;
static char g_ecdata_list[256] = "msvcp msvcr";
static BOOL g_ecdata_all, g_ecdata_off;
#define ECDATA_MAX 64
static struct { uint64_t image_va, rx; } g_ecdata_done[ECDATA_MAX];
static int g_ecdata_count;

extern void sys_icache_invalidate(void *start, size_t len);
static BOOL read_mem(uint64_t addr, void *out, size_t len);

static BOOL ecdata_wanted(const char *dll)
{
    if (g_ecdata_all) return YES;
    char buf[sizeof(g_ecdata_list)], *save = NULL;
    strlcpy(buf, g_ecdata_list, sizeof(buf));
    for (char *t = strtok_r(buf, " \t\r\n,;", &save); t; t = strtok_r(NULL, " \t\r\n,;", &save))
        if (!strncasecmp(dll, t, strlen(t))) return YES;
    return NO;
}

static void ecdata_alias(uint64_t rx, size_t len)
{
    const uint8_t *c = (const uint8_t *)(uintptr_t)(g_pool_rw + (rx - g_pool_rx));   // the copy, via the RW alias
    if (c[0] != 'M' || c[1] != 'Z') return;
    uint32_t pe;
    memcpy(&pe, c + 0x3c, 4);
    if (pe < 0x40 || pe > 0x800 || memcmp(c + pe, "PE\0\0", 4)) return;
    uint16_t nsec, optsz, magic;
    memcpy(&nsec, c + pe + 6, 2);
    memcpy(&optsz, c + pe + 20, 2);
    const uint8_t *opt = c + pe + 24;
    memcpy(&magic, opt, 2);
    if (magic != 0x20b || nsec == 0 || nsec > 96) return;
    uint32_t soi, hdrs;
    uint64_t image_va;
    memcpy(&image_va, opt + 24, 8);
    memcpy(&soi, opt + 56, 4);
    memcpy(&hdrs, opt + 60, 4);
    if (((soi + 0xfffu) & ~0xfffu) != ((len + 0xfff) & ~(size_t)0xfff)) return;   // not this image's copy
    const uint8_t *sec = opt + optsz;
    BOOL ec = NO;
    for (int i = 0; i < nsec; i++) if (!memcmp(sec + i * 40, ".hexpthk", 8)) ec = YES;
    if (!ec) return;                                                         // x64 or plain ARM64 image

    const char *name = "?";
    uint32_t exp_rva;
    memcpy(&exp_rva, opt + 112, 4);
    if (exp_rva && exp_rva + 16 < soi) {
        uint32_t nrva;
        memcpy(&nrva, c + exp_rva + 12, 4);
        if (nrva && nrva < soi) name = (const char *)(c + nrva);
    }
    if (!ecdata_wanted(name)) return;
    // A later pass may point the copy's header at the pool itself; that is
    // not an original image.
    if ((image_va >= g_pool_rx && image_va < g_pool_rx + g_pool_size) ||
        (image_va >= g_pool_rw && image_va < g_pool_rw + g_pool_size)) return;
    for (int k = 0; k < g_ecdata_count; k++)
        if (g_ecdata_done[k].image_va == image_va) {
            if (g_ecdata_done[k].rx != rx)      // the same copy invalidated again is routine
                pad_log("[madeira-pad] ecdata: another copy of %s (0x%llx) — the original stays tied to the first one\n",
                        name, (unsigned long long)image_va);
            return;
        }

    // The original must be mapped at the header's ImageBase and match the
    // copy byte for byte there; anything else means the address is wrong.
    uint8_t head[0x400];
    size_t cmp = hdrs && hdrs < sizeof(head) ? hdrs : sizeof(head);
    if (!read_mem(image_va, head, cmp) || memcmp(head, c, cmp)) {
        pad_log("[madeira-pad] ecdata: %s — original image not found at 0x%llx, left alone\n",
                name, (unsigned long long)image_va);
        return;
    }

    uint64_t limit_all = ((uint64_t)soi + 0x3fff) & ~0x3fffULL;
    int aliased = 0;
    for (int i = 0; i < nsec; i++) {
        const uint8_t *s = sec + i * 40;
        uint32_t vsz, va, rsz, ch;
        memcpy(&vsz, s + 8, 4); memcpy(&va, s + 12, 4); memcpy(&rsz, s + 16, 4); memcpy(&ch, s + 36, 4);
        if (!(ch & 0x80000000u) || (ch & 0x20000000u)) continue;            // writable, not code
        uint64_t size = vsz > rsz ? vsz : rsz;
        if (!size) continue;
        uint64_t limit = limit_all;
        for (int j = 0; j < nsec; j++) {
            uint32_t va2;
            memcpy(&va2, sec + j * 40 + 12, 4);
            if (va2 > va && va2 < limit) limit = va2;
        }
        uint64_t end = (va + size + 0x3fff) & ~0x3fffULL;
        if (end > limit) end = limit & ~0x3fffULL;                          // never touch the next section
        if (((image_va + va) & 0x3fff) || (((uintptr_t)c + va) & 0x3fff) || end <= va) {
            pad_log("[madeira-pad] ecdata: %s %.8s not on 16 KB pages in both views — skipped\n", name, (const char *)s);
            continue;
        }
        vm_address_t target = (vm_address_t)(image_va + va);
        vm_prot_t cur = 0, max = 0;
        kern_return_t kr = vm_remap(mach_task_self(), &target, (vm_size_t)(end - va), 0,
                                    VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(),
                                    (vm_address_t)((uintptr_t)c + va), FALSE, &cur, &max, VM_INHERIT_SHARE);
        if (kr != KERN_SUCCESS || target != (vm_address_t)(image_va + va)) {
            pad_log("[madeira-pad] ecdata: %s %.8s remap FAILED kr=%d — left as two copies\n", name, (const char *)s, kr);
            continue;
        }
        vm_protect(mach_task_self(), target, (vm_size_t)(end - va), FALSE, VM_PROT_READ | VM_PROT_WRITE);
        aliased++;
        pad_log("[madeira-pad] ecdata: %s %.8s 0x%llx+0x%llx now shares the pool copy's pages (0x%llx)\n",
                name, (const char *)s, (unsigned long long)(image_va + va), (unsigned long long)(end - va),
                (unsigned long long)(rx + va));
    }
    if (aliased && g_ecdata_count < ECDATA_MAX) {
        g_ecdata_done[g_ecdata_count].image_va = image_va;
        g_ecdata_done[g_ecdata_count].rx = rx;
        g_ecdata_count++;
    }
}

static void mp_sys_icache_invalidate(void *start, size_t len)
{
    sys_icache_invalidate(start, len);
    uint64_t a = (uint64_t)(uintptr_t)start;
    if (g_ecdata_off || len < 0x10000 || !g_pool_rx || !g_pool_rw || !g_pool_size) return;
    if (a < g_pool_rx || a + len > g_pool_rx + g_pool_size) return;
    ecdata_alias(a, len);
}

#pragma mark - VM watch (diagnostic)

// TEKKEN 8 (local-7 run): Unreal's persistent linear allocator reserves a big
// block with VirtualAlloc(MEM_RESERVE|MEM_TOP_DOWN, PAGE_NOACCESS) and treats
// the returned base as its own. That base came back as 0x7038ba0000 — where
// Wine had mapped apisetschema.dll read-only at process start — so the game's
// first write into it faulted and the main thread was killed. Wine's own view
// tree still shows the apiset file there, so the reservation never really
// took that range; which host call handed out the address is what this finds.
//
// Every host mapping call that touches the watched range (the apiset view,
// found automatically), and every mapping of 64 MB or more in the guest
// window, is logged to madeira-pad-log.txt with its result and the calling
// Madeira functions (symbolised from the app's own symbol table).

#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <errno.h>

static uint64_t g_watch_lo = 0x7038ba0000ULL, g_watch_hi = 0x7038bd0000ULL;
static BOOL g_watch_found;
static int g_vmw_events;
#define VMW_MAX 600
static volatile int g_vmw_busy;   // logging in progress (any thread): drop nested hits

typedef struct { uint64_t addr; const char *name; } vmw_sym;
static vmw_sym *g_syms;
static uint32_t g_nsyms;
static BOOL g_syms_tried;

static int vmw_sym_cmp(const void *a, const void *b)
{
    uint64_t x = ((const vmw_sym *)a)->addr, y = ((const vmw_sym *)b)->addr;
    return x < y ? -1 : x > y;
}

static void vmw_load_syms(void)
{
    g_syms_tried = YES;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!mh || mh->filetype != MH_EXECUTE) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct load_command *lc = (const struct load_command *)(mh + 1);
        const struct segment_command_64 *linkedit = NULL;
        const struct symtab_command *st = NULL;
        for (uint32_t k = 0; k < mh->ncmds; k++) {
            if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, "__LINKEDIT"))
                linkedit = (const struct segment_command_64 *)lc;
            else if (lc->cmd == LC_SYMTAB)
                st = (const struct symtab_command *)lc;
            lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
        }
        if (!linkedit || !st) return;
        uintptr_t le = linkedit->vmaddr + slide - linkedit->fileoff;
        const struct nlist_64 *nl = (const struct nlist_64 *)(le + st->symoff);
        const char *strs = (const char *)(le + st->stroff);
        g_syms = malloc(sizeof(vmw_sym) * st->nsyms);
        if (!g_syms) return;
        for (uint32_t k = 0; k < st->nsyms; k++) {
            if (nl[k].n_type & N_STAB) continue;
            if ((nl[k].n_type & N_TYPE) != N_SECT || nl[k].n_sect != 1) continue;   // __TEXT,__text
            g_syms[g_nsyms].addr = nl[k].n_value + slide;
            g_syms[g_nsyms].name = strs + nl[k].n_un.n_strx;
            g_nsyms++;
        }
        qsort(g_syms, g_nsyms, sizeof(vmw_sym), vmw_sym_cmp);
        return;
    }
}

static const char *vmw_symbolize(uint64_t pc, uint64_t *off)
{
    if (!g_syms_tried) vmw_load_syms();
    if (!g_nsyms || pc < g_syms[0].addr) return NULL;
    uint32_t lo = 0, hi = g_nsyms;
    while (hi - lo > 1) {
        uint32_t mid = (lo + hi) / 2;
        if (g_syms[mid].addr <= pc) lo = mid; else hi = mid;
    }
    *off = pc - g_syms[lo].addr;
    if (*off > 0x100000) return NULL;                 // past the end of the text section
    return g_syms[lo].name;
}

static void vmw_backtrace(void)
{
    uint64_t fp = (uint64_t)(uintptr_t)__builtin_frame_address(0);
    for (int i = 0; i < 8 && fp; i++) {
        uint64_t frame[2];
        if (!read_mem(fp, frame, sizeof(frame))) break;
        uint64_t ret = frame[1] & 0x0000007fffffffffULL, off = 0;
        const char *s = vmw_symbolize(ret, &off);
        pad_log("[vm-watch]      #%d 0x%llx %s+0x%llx\n", i, (unsigned long long)ret,
                s ? (s[0] == '_' ? s + 1 : s) : "?", (unsigned long long)off);
        if (frame[0] <= fp || frame[0] - fp > (8ULL << 20)) break;
        fp = frame[0];
    }
}

static inline BOOL vmw_hits(uint64_t a, uint64_t len)
{
    if (!len) return NO;
    if (a < g_watch_hi && a + len > g_watch_lo) return YES;
    return len >= (64ULL << 20) && (a == 0 || (a >= 0x7000000000ULL && a < 0x7400000000ULL));
}

/// One event; `a`/`len` is the request, `res` the address the call produced.
static void vmw_event(const char *what, uint64_t a, uint64_t len, uint64_t res, long rc, int prot, int flags, int fd)
{
    // Address test first: it is pure arithmetic, and all but a handful of
    // calls stop here.
    if (!vmw_hits(a, len) && !(res && res != (uint64_t)-1 && vmw_hits(res, len))) return;
    if (g_vmw_events >= VMW_MAX || !__sync_bool_compare_and_swap(&g_vmw_busy, 0, 1)) return;
    g_vmw_events++;
    pad_log("[vm-watch] %s req=0x%llx+0x%llx -> 0x%llx rc=%ld prot=%d flags=0x%x fd=%d%s\n",
            what, (unsigned long long)a, (unsigned long long)len, (unsigned long long)res, rc, prot, flags, fd,
            g_vmw_events == VMW_MAX ? " (last one logged)" : "");
    vmw_backtrace();
    g_vmw_busy = 0;
}

/// The apiset view: Wine maps apisetschema.dll (0x30000 bytes) read-only at
/// process start. Watch wherever it actually lands.
static void vmw_maybe_found(uint64_t res, size_t len, int prot, int fd)
{
    if (g_watch_found || fd < 0 || len != 0x30000 || prot != PROT_READ) return;
    if (res < 0x7000000000ULL || res >= 0x7400000000ULL) return;
    g_watch_found = YES;
    g_watch_lo = res;
    g_watch_hi = res + len;
    pad_log("[vm-watch] apiset view candidate at 0x%llx+0x30000 — watching it\n", (unsigned long long)res);
}

#pragma mark - launch override (setenv / unsetenv interposition)

static NSString *g_override_exe;
static NSString *g_override_args;
static BOOL g_override_armed;

// The override hijacks ONE button — "Stray (UE4, -dx11)" — so every other
// button keeps its own program. Replacing MADEIRA_EXE for all of them also
// hijacked "Wine Virtual Desktop" and "Steam Testing", which launch
// explorer.exe: the desktop then started the override's game instead, and
// looked like a crash.
static BOOL is_override_target(const char *value)
{
    return value && strstr(value, "Stray-Win64-Shipping.exe") != NULL;
}

static int mp_setenv(const char *name, const char *value, int overwrite)
{
    if (name && !strcmp(name, "MADEIRA_EXE")) {
        g_override_armed = g_override_exe && is_override_target(value);
        if (g_override_armed) {
            pad_log("[madeira-pad] launch override: MADEIRA_EXE %s -> %s\n",
                    value ? value : "(null)", g_override_exe.UTF8String);
            unsetenv("MADEIRA_DESKTOP");
            return setenv(name, g_override_exe.UTF8String, 1);
        }
    }
    if (name && g_override_armed && !strcmp(name, "MADEIRA_ARGS")) {
        if (g_override_args.length) return setenv(name, g_override_args.UTF8String, 1);
        return unsetenv(name);
    }
    if (name && value && !strcmp(name, "WINE_IOS_JIT_RW")) g_pool_rw = strtoull(value, NULL, 16);
    if (name && value && !strcmp(name, "WINE_IOS_JIT_SIZE")) g_pool_size = strtoull(value, NULL, 16);
    if (name && !strcmp(name, "WINE_IOS_JIT_RX") && value) {
        unsigned long long rx = strtoull(value, NULL, 16);
        g_pool_rx = rx;
        if (g_hold_base)
            pad_log("[madeira-pad] JIT pool RX=0x%llx ends 0x%llx, image base 0x%llx (%lld MB of slack)\n",
                    rx, rx + (g_pool_mb << 20), (unsigned long long)g_hold_base,
                    ((long long)g_hold_base - (long long)(rx + (g_pool_mb << 20))) >> 20);
        else
            pad_log("[madeira-pad] JIT pool RX=0x%llx\n", rx);
        dump_vm_map("JIT pool placed");
        return setenv(name, value, overwrite);
    }
    return setenv(name, value, overwrite);
}

static int mp_unsetenv(const char *name)
{
    if (name && g_override_armed && !strcmp(name, "MADEIRA_ARGS")) {
        if (g_override_args.length) return setenv(name, g_override_args.UTF8String, 1);
    }
    return unsetenv(name);
}

// Hand the image band over at the exact moment Wine's loader asks for that
// address, not before. Releasing it earlier (when the pool address was
// published) left a window in which ordinary allocations took the first 12 MB
// of the range, and the relocation-stripped image then failed with c0000018.
//
// On Apple platforms Wine's anon_mmap_tryfixed() reserves with mach_vm_map
// (VM_FLAGS_FIXED) FIRST and only then mmap()s, so mach_vm_map is the call
// that matters; the others are covered too in case another path is taken.
// Only a FIXED request for exactly the image base triggers the release, so an
// address scan that merely brushes the band cannot hand it away early. While
// the band is held, ANYWHERE allocations cannot land in it at all.
extern kern_return_t mach_vm_map(vm_map_t task, uint64_t *address, uint64_t size, uint64_t mask, int flags,
                                 mach_port_t object, uint64_t offset, boolean_t copy,
                                 vm_prot_t cur, vm_prot_t max, vm_inherit_t inherit);
extern kern_return_t mach_vm_allocate(vm_map_t task, uint64_t *address, uint64_t size, int flags);

static inline void release_if_image_base(uint64_t addr, BOOL fixed, const char *via)
{
    if (!g_hold_active || !fixed || addr != (uint64_t)g_hold_base) return;
    char why[96];
    snprintf(why, sizeof(why), "loader asked for the image base via %s", via);
    release_image_band(why);
}

extern kern_return_t mach_vm_deallocate(vm_map_t task, uint64_t address, uint64_t size);
extern kern_return_t mach_vm_protect(vm_map_t task, uint64_t address, uint64_t size, boolean_t set_max, vm_prot_t prot);
extern kern_return_t mach_vm_remap(vm_map_t task, uint64_t *target, uint64_t size, uint64_t mask, int flags,
                                   vm_map_t src_task, uint64_t src, boolean_t copy,
                                   vm_prot_t *cur, vm_prot_t *max, vm_inherit_t inherit);

static kern_return_t mp_mach_vm_map(vm_map_t task, uint64_t *address, uint64_t size, uint64_t mask, int flags,
                                    mach_port_t object, uint64_t offset, boolean_t copy,
                                    vm_prot_t cur, vm_prot_t max, vm_inherit_t inherit)
{
    uint64_t req = address ? *address : 0;
    if (address) release_if_image_base(req, !(flags & VM_FLAGS_ANYWHERE), "mach_vm_map");
    kern_return_t kr = mach_vm_map(task, address, size, mask, flags, object, offset, copy, cur, max, inherit);
    vmw_event("mach_vm_map", req, size, kr == KERN_SUCCESS && address ? *address : 0, kr, cur, flags, object ? 1 : -1);
    return kr;
}

static kern_return_t mp_mach_vm_allocate(vm_map_t task, uint64_t *address, uint64_t size, int flags)
{
    uint64_t req = address ? *address : 0;
    if (address) release_if_image_base(req, !(flags & VM_FLAGS_ANYWHERE), "mach_vm_allocate");
    kern_return_t kr = mach_vm_allocate(task, address, size, flags);
    vmw_event("mach_vm_allocate", req, size, kr == KERN_SUCCESS && address ? *address : 0, kr, 3, flags, -1);
    return kr;
}

static kern_return_t mp_vm_allocate(vm_map_t task, vm_address_t *address, vm_size_t size, int flags)
{
    uint64_t req = address ? *address : 0;
    if (address) release_if_image_base(req, !(flags & VM_FLAGS_ANYWHERE), "vm_allocate");
    kern_return_t kr = vm_allocate(task, address, size, flags);
    vmw_event("vm_allocate", req, size, kr == KERN_SUCCESS && address ? *address : 0, kr, 3, flags, -1);
    return kr;
}

static void *mp_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset)
{
    release_if_image_base((uint64_t)(uintptr_t)addr, (flags & MAP_FIXED) != 0, "mmap");
    void *r = mmap(addr, len, prot, flags, fd, offset);
    int err = errno;
    if (r != MAP_FAILED) vmw_maybe_found((uint64_t)(uintptr_t)r, len, prot, fd);
    vmw_event("mmap", (uint64_t)(uintptr_t)addr, len, r == MAP_FAILED ? (uint64_t)-1 : (uint64_t)(uintptr_t)r,
              r == MAP_FAILED ? err : 0, prot, flags, fd);
    errno = err;
    return r;
}

static int mp_munmap(void *addr, size_t len)
{
    int r = munmap(addr, len), err = errno;
    vmw_event("munmap", (uint64_t)(uintptr_t)addr, len, 0, r ? err : 0, 0, 0, -1);
    errno = err;
    return r;
}

static int mp_mprotect(void *addr, size_t len, int prot)
{
    int r = mprotect(addr, len, prot), err = errno;
    vmw_event("mprotect", (uint64_t)(uintptr_t)addr, len, 0, r ? err : 0, prot, 0, -1);
    errno = err;
    return r;
}

static kern_return_t mp_vm_protect(vm_map_t task, vm_address_t addr, vm_size_t len, boolean_t set_max, vm_prot_t prot)
{
    kern_return_t kr = vm_protect(task, addr, len, set_max, prot);
    vmw_event(set_max ? "vm_protect(max)" : "vm_protect", addr, len, 0, kr, prot, 0, -1);
    return kr;
}

static kern_return_t mp_mach_vm_protect(vm_map_t task, uint64_t addr, uint64_t len, boolean_t set_max, vm_prot_t prot)
{
    kern_return_t kr = mach_vm_protect(task, addr, len, set_max, prot);
    vmw_event(set_max ? "mach_vm_protect(max)" : "mach_vm_protect", addr, len, 0, kr, prot, 0, -1);
    return kr;
}

static kern_return_t mp_vm_deallocate(vm_map_t task, vm_address_t addr, vm_size_t len)
{
    kern_return_t kr = vm_deallocate(task, addr, len);
    vmw_event("vm_deallocate", addr, len, 0, kr, 0, 0, -1);
    return kr;
}

static kern_return_t mp_mach_vm_deallocate(vm_map_t task, uint64_t addr, uint64_t len)
{
    kern_return_t kr = mach_vm_deallocate(task, addr, len);
    vmw_event("mach_vm_deallocate", addr, len, 0, kr, 0, 0, -1);
    return kr;
}

static kern_return_t mp_mach_vm_remap(vm_map_t task, uint64_t *target, uint64_t size, uint64_t mask, int flags,
                                      vm_map_t src_task, uint64_t src, boolean_t copy,
                                      vm_prot_t *cur, vm_prot_t *max, vm_inherit_t inherit)
{
    uint64_t req = target ? *target : 0;
    kern_return_t kr = mach_vm_remap(task, target, size, mask, flags, src_task, src, copy, cur, max, inherit);
    vmw_event("mach_vm_remap", req, size, kr == KERN_SUCCESS && target ? *target : 0, kr, cur ? *cur : 0, flags, -1);
    return kr;
}

static kern_return_t mp_vm_remap(vm_map_t task, vm_address_t *target, vm_size_t size, vm_address_t mask, int flags,
                                 vm_map_t src_task, vm_address_t src, boolean_t copy,
                                 vm_prot_t *cur, vm_prot_t *max, vm_inherit_t inherit)
{
    uint64_t req = target ? *target : 0;
    kern_return_t kr = vm_remap(task, target, size, mask, flags, src_task, src, copy, cur, max, inherit);
    vmw_event("vm_remap", req, size, kr == KERN_SUCCESS && target ? *target : 0, kr, cur ? *cur : 0, flags, -1);
    return kr;
}

typedef struct { const void *replacement; const void *replacee; } interpose_t;
__attribute__((used)) static const interpose_t g_interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)(unsigned long)&mp_setenv,   (const void *)(unsigned long)&setenv },
    { (const void *)(unsigned long)&mp_unsetenv, (const void *)(unsigned long)&unsetenv },
    { (const void *)(unsigned long)&mp_mmap,     (const void *)(unsigned long)&mmap },
    { (const void *)(unsigned long)&mp_mach_vm_map,      (const void *)(unsigned long)&mach_vm_map },
    { (const void *)(unsigned long)&mp_mach_vm_allocate, (const void *)(unsigned long)&mach_vm_allocate },
    { (const void *)(unsigned long)&mp_vm_allocate,      (const void *)(unsigned long)&vm_allocate },
    { (const void *)(unsigned long)&mp_sys_icache_invalidate, (const void *)(unsigned long)&sys_icache_invalidate },
    { (const void *)(unsigned long)&mp_munmap,             (const void *)(unsigned long)&munmap },
    { (const void *)(unsigned long)&mp_mprotect,           (const void *)(unsigned long)&mprotect },
    { (const void *)(unsigned long)&mp_vm_protect,         (const void *)(unsigned long)&vm_protect },
    { (const void *)(unsigned long)&mp_mach_vm_protect,    (const void *)(unsigned long)&mach_vm_protect },
    { (const void *)(unsigned long)&mp_vm_deallocate,      (const void *)(unsigned long)&vm_deallocate },
    { (const void *)(unsigned long)&mp_mach_vm_deallocate, (const void *)(unsigned long)&mach_vm_deallocate },
    { (const void *)(unsigned long)&mp_mach_vm_remap,      (const void *)(unsigned long)&mach_vm_remap },
    { (const void *)(unsigned long)&mp_vm_remap,           (const void *)(unsigned long)&vm_remap },
};

#pragma mark - rumble

@interface MPRumble : NSObject
@property (nonatomic, strong) CHHapticEngine *engine;
@property (nonatomic, strong) id<CHHapticAdvancedPatternPlayer> player;
- (instancetype)initWithController:(GCController *)c;
- (void)setStrength:(float)strength sharpness:(float)sharpness;
- (void)stop;
@end

@implementation MPRumble
- (instancetype)initWithController:(GCController *)c
{
    if (!(self = [super init])) return nil;
    if (!c.haptics) return nil;
    _engine = [c.haptics createEngineWithLocality:GCHapticsLocalityDefault];
    if (!_engine) return nil;
    _engine.autoShutdownEnabled = YES;
    __weak MPRumble *weakSelf = self;
    _engine.resetHandler = ^{
        MPRumble *s = weakSelf;
        s.player = nil;
        [s.engine startAndReturnError:nil];
    };
    [_engine startAndReturnError:nil];
    return self;
}

- (void)setStrength:(float)strength sharpness:(float)sharpness
{
    if (strength <= 0.02f) { [self stop]; return; }
    if (!self.player) {
        CHHapticEventParameter *i = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1.0];
        CHHapticEventParameter *s = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.4];
        CHHapticEvent *ev = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                         parameters:@[i, s] relativeTime:0 duration:30];
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[ev] parameters:@[] error:nil];
        if (!pattern) return;
        id<CHHapticAdvancedPatternPlayer> p = [self.engine createAdvancedPlayerWithPattern:pattern error:nil];
        if (!p) return;
        p.loopEnabled = YES;
        [self.engine startAndReturnError:nil];
        [p startAtTime:CHHapticTimeImmediate error:nil];
        self.player = p;
    }
    CHHapticDynamicParameter *di = [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:strength relativeTime:0];
    CHHapticDynamicParameter *ds = [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:sharpness - 0.4f relativeTime:0];
    [self.player sendParameters:@[di, ds] atTime:CHHapticTimeImmediate error:nil];
}

- (void)stop
{
    [self.player stopAtTime:CHHapticTimeImmediate error:nil];
    self.player = nil;
}
@end

#pragma mark - pad state

static void put16(int slot, int off, uint16_t v) { memcpy(g_block + HEADER + SLOT_SIZE * slot + off, &v, 2); }
static void put32(int slot, int off, uint32_t v) { memcpy(g_block + HEADER + SLOT_SIZE * slot + off, &v, 4); }
static uint16_t get16(int slot, int off) { uint16_t v; memcpy(&v, g_block + HEADER + SLOT_SIZE * slot + off, 2); return v; }
static uint32_t get32(int slot, int off) { uint32_t v; memcpy(&v, g_block + HEADER + SLOT_SIZE * slot + off, 4); return v; }

static int16_t axis(float v) { float x = v * 32767.0f; if (x > 32767) x = 32767; if (x < -32768) x = -32768; return (int16_t)x; }
static uint8_t trig(float v) { float x = v * 255.0f; if (x > 255) x = 255; if (x < 0) x = 0; return (uint8_t)x; }

/* Runs on g_queue (the controllers' handler queue). */
static void publish(int i)
{
    uint16_t b = 0; uint8_t lt = 0, rt = 0; int16_t lx = 0, ly = 0, rx = 0, ry = 0;
    uint8_t btype = 0, blevel = 0;
    GCExtendedGamepad *pad = g_pads[i].extendedGamepad;
    if (pad) {
#define B(e, m) if ((e).isPressed) b |= (m)
        B(pad.dpad.up, 0x0001); B(pad.dpad.down, 0x0002); B(pad.dpad.left, 0x0004); B(pad.dpad.right, 0x0008);
        B(pad.buttonMenu, 0x0010);
        if (pad.buttonOptions) B(pad.buttonOptions, 0x0020);
        if (pad.leftThumbstickButton) B(pad.leftThumbstickButton, 0x0040);
        if (pad.rightThumbstickButton) B(pad.rightThumbstickButton, 0x0080);
        B(pad.leftShoulder, 0x0100); B(pad.rightShoulder, 0x0200);
        if (pad.buttonHome) B(pad.buttonHome, 0x0400);
        B(pad.buttonA, 0x1000); B(pad.buttonB, 0x2000); B(pad.buttonX, 0x4000); B(pad.buttonY, 0x8000);
#undef B
        lt = trig(pad.leftTrigger.value); rt = trig(pad.rightTrigger.value);
        lx = axis(pad.leftThumbstick.xAxis.value); ly = axis(pad.leftThumbstick.yAxis.value);
        rx = axis(pad.rightThumbstick.xAxis.value); ry = axis(pad.rightThumbstick.yAxis.value);
        GCDeviceBattery *bat = g_pads[i].battery;
        if (bat) {
            if (bat.batteryState == GCDeviceBatteryStateCharging || bat.batteryState == GCDeviceBatteryStateFull) { btype = 1; blevel = 3; }
            else { btype = 3; int l = (int)(bat.batteryLevel * 4); blevel = (uint8_t)(l > 3 ? 3 : l < 0 ? 0 : l); }
        }
    }
    g_packets[i]++;
    put16(i, 8, b);
    g_block[HEADER + SLOT_SIZE * i + 10] = lt;
    g_block[HEADER + SLOT_SIZE * i + 11] = rt;
    put16(i, 12, (uint16_t)lx); put16(i, 14, (uint16_t)ly);
    put16(i, 16, (uint16_t)rx); put16(i, 18, (uint16_t)ry);
    g_block[HEADER + SLOT_SIZE * i + 28] = btype;
    g_block[HEADER + SLOT_SIZE * i + 29] = blevel;
    put32(i, 4, g_packets[i]);                 // packet before connected: never "connected with stale data"
    put32(i, 0, pad ? 1 : 0);
}

static void connect_pad(GCController *c)
{
    if (!c.extendedGamepad) return;
    for (int i = 0; i < SLOTS; i++) if (g_pads[i] == c) return;
    int slot = -1;
    for (int i = 0; i < SLOTS; i++) if (!g_pads[i]) { slot = i; break; }
    if (slot < 0) return;
    g_pads[slot] = c;
    c.playerIndex = (GCControllerPlayerIndex)slot;
    c.handlerQueue = g_queue;
    c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *gp, GCControllerElement *el) { publish(slot); };
    g_rumble[slot] = [[MPRumble alloc] initWithController:c];
    dispatch_async(g_queue, ^{ publish(slot); });
    pad_log("[madeira-pad] controller '%s' -> XInput player %d (rumble=%s)\n",
            c.vendorName.UTF8String ?: "?", slot + 1, g_rumble[slot] ? "yes" : "no");
}

static void disconnect_pad(GCController *c)
{
    for (int i = 0; i < SLOTS; i++) {
        if (g_pads[i] != c) continue;
        g_pads[i] = nil;
        [(MPRumble *)g_rumble[i] stop];
        g_rumble[i] = nil;
        dispatch_async(g_queue, ^{ publish(i); });
        pad_log("[madeira-pad] XInput player %d disconnected\n", i + 1);
    }
}

static void pump_rumble(void)
{
    for (int i = 0; i < SLOTS; i++) {
        MPRumble *r = g_rumble[i];
        if (!r) continue;
        uint32_t seq = get32(i, 24);
        if (seq == g_last_rumble[i]) continue;
        g_last_rumble[i] = seq;
        uint16_t l = get16(i, 20), h = get16(i, 22);
        [r setStrength:(float)(l > h ? l : h) / 65535.0f sharpness:(float)h / 65535.0f];
    }
}

#pragma mark - stall watch

// A protected game reaches its entry point and then spins in its own startup
// code with no window and no frames (Stellar Blade's demo did that for 13
// minutes). The app's "diagnostics" switch does not help there — it only gates
// two log lines — and its watchdog prints the HOST pc, which is somewhere in
// FEX's translated code and says nothing about the game.
//
// So: watch the DXMT present counter, and if nothing has been presented after
// the grace period, sample every thread that is running translated code and
// print its GUEST x86-64 state. In FEX's arm64 JIT x28 holds the CPU state
// pointer; RIP is at +0x18 (block-granular) and the 16 GPRs at +0x20 — the
// same layout the Wine side reads for [int3-guest]. A loop shows up as the
// same few RIPs over and over; resolve them against the [jit-pool] image lines.
// Documents/madeira-stallwatch.txt holds the seconds, or "0" to disable.

static int g_stall_seconds = 45;
static uint64_t (*g_get_presents)(void);

#define RIP_SLOTS 64
static struct { uint64_t rip; unsigned hits; } g_rips[RIP_SLOTS];
static unsigned g_samples;

static BOOL read_mem(uint64_t addr, void *out, size_t len)
{
    vm_size_t got = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)addr, len, (vm_address_t)out, &got) == KERN_SUCCESS
        && got == len;
}

static void note_rip(uint64_t rip)
{
    for (int i = 0; i < RIP_SLOTS; i++) {
        if (g_rips[i].rip == rip) { g_rips[i].hits++; return; }
        if (!g_rips[i].rip) { g_rips[i].rip = rip; g_rips[i].hits = 1; return; }
    }
}

static void sample_guest_threads(BOOL verbose)
{
    if (!g_pool_rx) return;
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t n = 0;
    if (task_threads(mach_task_self(), &threads, &n) != KERN_SUCCESS) return;
    thread_t self = mach_thread_self();
    unsigned in_jit = 0;
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        if (threads[i] == self) continue;
        arm_thread_state64_t st;
        mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
        // For another thread XNU stops it for the copy and resumes it: no
        // explicit suspend, so no risk of freezing a thread that holds a lock
        // this code then needs.
        if (thread_get_state(threads[i], ARM_THREAD_STATE64, (thread_state_t)&st, &cnt) != KERN_SUCCESS) continue;
        uint64_t pc = arm_thread_state64_get_pc(st);
        if (pc < g_pool_rx || pc >= g_pool_rx + (1200ULL << 20)) continue;   // not in the JIT pool
        uint64_t state = st.__x[28], rip = 0, g[16];
        if (state < 0x100000000ULL || !read_mem(state + 0x18, &rip, 8) || !read_mem(state + 0x20, g, sizeof(g))) {
            if (verbose) pad_log("[madeira-pad]   thread #%u native pc=pool+0x%llx (Arm64EC/Wine code, not guest x86)\n",
                                 i, (unsigned long long)(pc - g_pool_rx));
            continue;
        }
        in_jit++;
        note_rip(rip);
        if (verbose)
            pad_log("[madeira-pad]   thread #%u guest RIP=0x%llx RSP=0x%llx RAX=%llx RCX=%llx RDX=%llx RBX=%llx "
                    "RBP=%llx RSI=%llx RDI=%llx R8=%llx R9=%llx (host pc=pool+0x%llx)\n",
                    i, (unsigned long long)rip, (unsigned long long)g[4], (unsigned long long)g[0],
                    (unsigned long long)g[1], (unsigned long long)g[2], (unsigned long long)g[3],
                    (unsigned long long)g[5], (unsigned long long)g[6], (unsigned long long)g[7],
                    (unsigned long long)g[8], (unsigned long long)g[9], (unsigned long long)(pc - g_pool_rx));
    }
    for (mach_msg_type_number_t i = 0; i < n; i++) mach_port_deallocate(mach_task_self(), threads[i]);
    mach_port_deallocate(mach_task_self(), self);
    vm_deallocate(mach_task_self(), (vm_address_t)threads, n * sizeof(thread_t));
    g_samples++;
    if (verbose) pad_log("[madeira-pad]   %u of %u threads were in translated guest code\n", in_jit, n);
}

static void print_rip_histogram(void)
{
    pad_log("[madeira-pad] guest RIP histogram after %u samples (hits, RIP) — a spin loop is the top few:\n", g_samples);
    for (int shown = 0; shown < 12; shown++) {
        int best = -1;
        for (int i = 0; i < RIP_SLOTS; i++)
            if (g_rips[i].rip && g_rips[i].hits && (best < 0 || g_rips[i].hits > g_rips[best].hits)) best = i;
        if (best < 0) break;
        pad_log("[madeira-pad]   %5u  0x%llx\n", g_rips[best].hits, (unsigned long long)g_rips[best].rip);
        g_rips[best].hits = 0;           // consumed; the slot stays so the RIP is not re-added
    }
    memset(g_rips, 0, sizeof(g_rips));
}

static void stall_tick(void)
{
    static int elapsed, since;
    static BOOL announced;
    if (g_stall_seconds <= 0 || !g_get_presents || !g_pool_rx) return;
    if (g_get_presents() > 0) {
        if (announced) { pad_log("[madeira-pad] first frame presented — sampler stopped\n"); announced = NO; }
        g_stall_seconds = 0;             // it drew something: stay quiet for the rest of the run
        return;
    }
    if (++elapsed < g_stall_seconds) return;
    if (!announced) {
        announced = YES;
        pad_log("[madeira-pad] no frame after %ds — sampling guest threads (every second, "
                "full dump every 30 s)\n", g_stall_seconds);
        dump_vm_map("stalled");
        sample_guest_threads(YES);
        return;
    }
    since++;
    BOOL full = (since % 30) == 0;
    sample_guest_threads(full);
    if (full) print_rip_histogram();
}

#pragma mark - init

static void set_default(const char *k, const char *v) { setenv(k, v, 0); }

__attribute__((constructor))
static void madeira_pad_init(void)
{
    @autoreleasepool {
        // Controller block. Never freed: Wine keeps the address for the process lifetime.
        g_block = calloc(1, HEADER + SLOT_SIZE * SLOTS);
        uint32_t magic = 0x4441504D, version = 1, count = SLOTS, size = SLOT_SIZE;
        memcpy(g_block, &magic, 4); memcpy(g_block + 4, &version, 4);
        memcpy(g_block + 8, &count, 4); memcpy(g_block + 12, &size, 4);
        char addr[32];
        snprintf(addr, sizeof(addr), "%lx", (unsigned long)(uintptr_t)g_block);
        setenv("MADEIRA_PAD_SHM", addr, 1);
        g_queue = dispatch_queue_create("madeira.pad", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));

        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSFileManager *fm = NSFileManager.defaultManager;

        // Before the app rotates madeira-log.txt (its LogStore starts after
        // every dylib constructor), keep the previous real run.
        archive_previous_log(docs);
        g_padlog = fopen([docs stringByAppendingPathComponent:@"madeira-pad-log.txt"].fileSystemRepresentation, "w");
        {
            NSDateFormatter *f = [NSDateFormatter new];
            f.dateFormat = @"yyyy-MM-dd HH:mm:ss";
            pad_log("[madeira-pad] ---- process start %s (pid %d) ----\n", [f stringFromDate:NSDate.date].UTF8String, getpid());
        }

        NSString *ib = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"madeira-imagebase.txt"]
                                                encoding:NSUTF8StringEncoding error:nil];
        if (ib.length) {
            NSArray<NSString *> *f = [ib.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            unsigned long long base = f.count > 0 ? strtoull(f[0].UTF8String, NULL, 16) : 0;
            unsigned long long mb = f.count > 1 ? strtoull(f[1].UTF8String, NULL, 10) : 0;
            if (!base) g_hold_disabled = YES;
            else { g_hold_base = (vm_address_t)base; if (mb) g_hold_size = (vm_size_t)(mb << 20); }
        }

        // Persistent caches (Documents is never purged; Library/Caches is).
        NSString *dxmt = [docs stringByAppendingPathComponent:@"madeira-cache/dxmt/"];
        NSString *vkd3d = [docs stringByAppendingPathComponent:@"wine/drive_c/madeira-cache/vkd3d"];
        [fm createDirectoryAtPath:dxmt withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:vkd3d withIntermediateDirectories:YES attributes:nil error:nil];
        set_default("DXMT_SHADER_CACHE_PATH", [dxmt stringByAppendingString:@"/"].UTF8String);
        set_default("VKD3D_SHADER_CACHE_PATH", "C:\\madeira-cache\\vkd3d");
        set_default("VKD3D_DEBUG", "none");
        set_default("VKD3D_SHADER_DEBUG", "none");
        set_default("MVK_CONFIG_LOG_LEVEL", "1");
        set_default("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "1");
        set_default("MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION", "1");
        set_default("MVK_CONFIG_RESUME_LOST_DEVICE", "1");

        // KUSER_SHARED_DATA clock. Without it SystemTime / InterruptTime /
        // TickCount never advance, so anything that waits on GetTickCount or
        // DateTime.UtcNow waits forever — which looks exactly like the black
        // screen a protected title shows while spinning in its startup code.
        // Documents/madeira-usd-time.txt still wins (the app sets it with
        // overwrite), so "0" there turns it back off.
        set_default("MADEIRA_USD_TIME", "1");

        NSString *sw = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"madeira-stallwatch.txt"]
                                                encoding:NSUTF8StringEncoding error:nil];
        if (sw.length) g_stall_seconds = sw.intValue;
        // Exported by the app binary (DXMT present counter).
        g_get_presents = dlsym(RTLD_DEFAULT, "madeira_get_present_count");
        if (!g_get_presents) pad_log("[madeira-pad] madeira_get_present_count not found — stall sampler off\n");

        NSString *ecd = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"madeira-ecdata.txt"]
                                                 encoding:NSUTF8StringEncoding error:nil];
        ecd = [ecd stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (ecd.length) {
            if ([ecd isEqualToString:@"0"]) g_ecdata_off = YES;
            else if ([ecd.lowercaseString isEqualToString:@"all"]) g_ecdata_all = YES;
            else strlcpy(g_ecdata_list, ecd.UTF8String, sizeof(g_ecdata_list));
        }
        pad_log("[madeira-pad] ARM64EC data sharing: %s\n",
                g_ecdata_off ? "off (madeira-ecdata.txt)" : g_ecdata_all ? "all ARM64EC DLLs" : g_ecdata_list);

        // Extra environment. Documents/madeira-env.txt, one KEY=VALUE per line
        // (# comments and blank lines ignored), each applied with overwrite so
        // it beats the app's own defaults. This is how vkd3d/MoltenVK/Wine can
        // be reconfigured — e.g. VKD3D_DEBUG=warn, VKD3D_CONFIG=..., MVK_CONFIG_*
        // — without rebuilding the app for every experiment. Wine snapshots the
        // environment when it starts the guest, and this runs first.
        NSString *envtxt = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"madeira-env.txt"]
                                                     encoding:NSUTF8StringEncoding error:nil];
        if (envtxt.length) {
            for (NSString *raw in [envtxt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
                NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if (!line.length || [line hasPrefix:@"#"]) continue;
                NSRange eq = [line rangeOfString:@"="];
                if (eq.location == NSNotFound || eq.location == 0) continue;
                NSString *k = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                NSString *v = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if (!k.length) continue;
                setenv(k.UTF8String, v.UTF8String, 1);
                pad_log("[madeira-pad] env: %s=%s (madeira-env.txt)\n", k.UTF8String, v.UTF8String);
            }
        }

        // Launch override.
        NSString *launch = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"madeira-launch.txt"]
                                                     encoding:NSUTF8StringEncoding error:nil];
        if (launch.length) {
            NSArray<NSString *> *lines = [launch componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
            NSString *exe = [lines.firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (exe.length) {
                g_override_exe = exe;
                g_override_args = lines.count > 1 ? [lines[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : @"";
                pad_log("[madeira-pad] madeira-launch.txt: exe=%s args=%s\n", exe.UTF8String, g_override_args.UTF8String);
            }
        }

        // Pool size and image band depend on what is about to be launched, so
        // this runs after the launch file is read and before anything big is
        // allocated.
        dump_vm_map("app start");
        plan_for_fixed_base_image(docs, g_override_exe);

        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification *n) { connect_pad(n.object); }];
            [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification *n) { disconnect_pad(n.object); }];
            for (GCController *c in GCController.controllers) connect_pad(c);
            dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(t, DISPATCH_TIME_NOW, NSEC_PER_SEC / 30, NSEC_PER_SEC / 100);
            dispatch_source_set_event_handler(t, ^{
                pump_rumble();
                static int n;
                if (++n >= 30) { n = 0; stall_tick(); }      // once a second
            });
            dispatch_resume(t);
            static dispatch_source_t keep;   // keep the timer alive
            keep = t;
        });
        pad_log("[madeira-pad] loaded: MADEIRA_PAD_SHM=%s\n", addr);
    }
}
