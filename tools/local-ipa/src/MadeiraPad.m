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

#define SLOTS 4
#define SLOT_SIZE 32
#define HEADER 16

static uint8_t *g_block;
static GCController *g_pads[SLOTS];
static uint32_t g_packets[SLOTS];
static uint32_t g_last_rumble[SLOTS];
static id g_rumble[SLOTS];          // MPRumble
static dispatch_queue_t g_queue;

#pragma mark - image-base reservation

// Why this exists: a Windows executable built with relocations stripped can
// ONLY be mapped at its preferred base. Unreal shipping binaries use
// 0x140000000, and protected ones (Stellar Blade's SB-Win64-Shipping.exe) have
// no .reloc at all. Madeira's JIT pool is allocated later by StikDebug with
// VM_FLAGS_ANYWHERE, after pin chunks push the allocator past 0x119000000, so
// it repeatedly lands across 0x140000000 — and Wine then dies with
//   wine: failed to create main module ... status c0000018
// (ntdll's perform_relocations: "need to relocate but there are no relocation
// records" = STATUS_CONFLICTING_ADDRESSES).
//
// So: reserve that band here, at dylib load, long before the pool exists. The
// pool cannot overlap a reserved range, so the kernel places it elsewhere. The
// band is released the moment the pool address is published (WINE_IOS_JIT_RX),
// which is after the pool is allocated and before Wine maps any image.
//
// Reserve-only (VM_PROT_NONE, never touched), so it costs address space and no
// memory. Documents/madeira-imagebase.txt overrides it: "<hex base> <MB>", or
// "0" to disable.

static vm_address_t g_hold_base = 0x140000000ULL;
static vm_size_t g_hold_size = 0x20000000ULL;      // 512 MB, covers a 314 MB image
static BOOL g_hold_active;

static void hold_image_band(void)
{
    if (!g_hold_size) return;
    vm_address_t addr = g_hold_base;
    // mach_vm_* is not declared in the iOS SDK; vm_* is, and on arm64 its
    // addresses are already 64-bit.
    kern_return_t kr = vm_allocate(mach_task_self(), &addr, g_hold_size, VM_FLAGS_FIXED);
    if (kr != KERN_SUCCESS || addr != g_hold_base) {
        if (kr == KERN_SUCCESS) vm_deallocate(mach_task_self(), addr, g_hold_size);
        fprintf(stderr, "[madeira-pad] image band 0x%llx+%lluMB NOT reserved (kr=%d) — "
                        "relocation-stripped games may fail with c0000018\n",
                (unsigned long long)g_hold_base, (unsigned long long)(g_hold_size >> 20), kr);
        return;
    }
    vm_protect(mach_task_self(), addr, g_hold_size, FALSE, VM_PROT_NONE);
    g_hold_active = YES;
    fprintf(stderr, "[madeira-pad] image band reserved 0x%llx..0x%llx (JIT pool must go elsewhere)\n",
            (unsigned long long)g_hold_base, (unsigned long long)(g_hold_base + g_hold_size));
}

static void release_image_band(const char *pool_rx)
{
    if (!g_hold_active) return;
    vm_deallocate(mach_task_self(), g_hold_base, g_hold_size);
    g_hold_active = NO;
    unsigned long long rx = pool_rx ? strtoull(pool_rx, NULL, 16) : 0;
    const char *verdict = "";
    if (rx) {
        // 896 MB default pool; only the overlap verdict matters here.
        unsigned long long pool_end = rx + (896ULL << 20);
        verdict = (rx < g_hold_base + g_hold_size && pool_end > g_hold_base)
                  ? " ** POOL STILL OVERLAPS — relocation-stripped games will fail **" : " (pool clear)";
    }
    fprintf(stderr, "[madeira-pad] image band released for the loader; pool RX=%s%s\n",
            pool_rx ? pool_rx : "?", verdict);
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
            fprintf(stderr, "[madeira-pad] launch override: MADEIRA_EXE %s -> %s\n",
                    value ? value : "(null)", g_override_exe.UTF8String);
            unsetenv("MADEIRA_DESKTOP");
            return setenv(name, g_override_exe.UTF8String, 1);
        }
    }
    if (name && g_override_armed && !strcmp(name, "MADEIRA_ARGS")) {
        if (g_override_args.length) return setenv(name, g_override_args.UTF8String, 1);
        return unsetenv(name);
    }
    // The pool exists by the time its address is published: give the loader the
    // image band back before Wine maps anything.
    if (name && !strcmp(name, "WINE_IOS_JIT_RX")) {
        int r = setenv(name, value, overwrite);
        release_image_band(value);
        return r;
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

typedef struct { const void *replacement; const void *replacee; } interpose_t;
__attribute__((used)) static const interpose_t g_interposers[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)(unsigned long)&mp_setenv,   (const void *)(unsigned long)&setenv },
    { (const void *)(unsigned long)&mp_unsetenv, (const void *)(unsigned long)&unsetenv },
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
    fprintf(stderr, "[madeira-pad] controller '%s' -> XInput player %d (rumble=%s)\n",
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
        fprintf(stderr, "[madeira-pad] XInput player %d disconnected\n", i + 1);
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

        // Before anything else allocates: keep the classic Windows image base free.
        NSString *ib = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"madeira-imagebase.txt"]
                                                encoding:NSUTF8StringEncoding error:nil];
        if (ib.length) {
            NSArray<NSString *> *f = [ib.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            unsigned long long base = f.count > 0 ? strtoull(f[0].UTF8String, NULL, 16) : 0;
            unsigned long long mb = f.count > 1 ? strtoull(f[1].UTF8String, NULL, 10) : 512;
            if (!base) { g_hold_size = 0; fprintf(stderr, "[madeira-pad] image band disabled by madeira-imagebase.txt\n"); }
            else { g_hold_base = (vm_address_t)base; g_hold_size = (vm_size_t)(mb << 20); }
        }
        hold_image_band();

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

        // Launch override.
        NSString *launch = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"madeira-launch.txt"]
                                                     encoding:NSUTF8StringEncoding error:nil];
        if (launch.length) {
            NSArray<NSString *> *lines = [launch componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
            NSString *exe = [lines.firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (exe.length) {
                g_override_exe = exe;
                g_override_args = lines.count > 1 ? [lines[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : @"";
                fprintf(stderr, "[madeira-pad] madeira-launch.txt: exe=%s args=%s\n", exe.UTF8String, g_override_args.UTF8String);
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification *n) { connect_pad(n.object); }];
            [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification *n) { disconnect_pad(n.object); }];
            for (GCController *c in GCController.controllers) connect_pad(c);
            dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(t, DISPATCH_TIME_NOW, NSEC_PER_SEC / 30, NSEC_PER_SEC / 100);
            dispatch_source_set_event_handler(t, ^{ pump_rumble(); });
            dispatch_resume(t);
            static dispatch_source_t keep;   // keep the timer alive
            keep = t;
        });
        fprintf(stderr, "[madeira-pad] loaded: MADEIRA_PAD_SHM=%s\n", addr);
    }
}
