/*
 * Madeira XInput — xinput1_1..1_4 / xinput9_1_0 for Windows games on iOS.
 *
 * Wine's xinput reads controllers through HID (winebus.sys), which has no
 * backend on iOS, so games saw no pads at all. Madeira runs Wine inside the app
 * process, so this DLL reads controller state straight from a block the app
 * fills from GameController.framework (app/Madeira/Gamepad.swift). The block's
 * address arrives in MADEIRA_PAD_SHM (hex). Rumble goes the other way: the game
 * writes motor speeds here and the app plays them on the controller's haptics.
 *
 * Layout must match Gamepad.swift exactly (static asserts below). Without the
 * variable or with a bad magic every call reports ERROR_DEVICE_NOT_CONNECTED,
 * i.e. the same "no controller" behaviour as before.
 *
 * Built as an ARM64X hybrid (-marm64x) so it loads in the ARM64EC processes
 * x86-64 games run in; exported functions get x64 entry thunks from the compiler.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define MPAD_MAGIC   0x4441504DU  /* "MPAD" little-endian */
#define MPAD_VERSION 1U
#define MPAD_SLOTS   4

typedef struct {
    uint32_t connected;
    uint32_t packet;
    uint16_t buttons;
    uint8_t  left_trigger;
    uint8_t  right_trigger;
    int16_t  lx, ly, rx, ry;
    uint16_t rumble_left;      /* written by the game */
    uint16_t rumble_right;     /* written by the game */
    uint32_t rumble_seq;       /* written by the game */
    uint8_t  battery_type;
    uint8_t  battery_level;
    uint8_t  reserved[2];
} mpad_slot;

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t slot_count;
    uint32_t slot_size;
    mpad_slot slots[MPAD_SLOTS];
} mpad_shm;

_Static_assert(sizeof(mpad_slot) == 32, "mpad_slot layout");
_Static_assert(sizeof(mpad_shm) == 16 + 32 * MPAD_SLOTS, "mpad_shm layout");

/* XInput ABI (declared locally: mingw's xinput.h marks these dllimport). */
typedef struct { WORD wButtons; BYTE bLeftTrigger; BYTE bRightTrigger; SHORT sThumbLX, sThumbLY, sThumbRX, sThumbRY; } MX_GAMEPAD;
typedef struct { DWORD dwPacketNumber; MX_GAMEPAD Gamepad; } MX_STATE;
typedef struct { WORD wLeftMotorSpeed; WORD wRightMotorSpeed; } MX_VIBRATION;
typedef struct { BYTE Type; BYTE SubType; WORD Flags; MX_GAMEPAD Gamepad; MX_VIBRATION Vibration; } MX_CAPABILITIES;
typedef struct { MX_CAPABILITIES Capabilities; WORD VendorId; WORD ProductId; WORD VersionNumber; WORD unk1; DWORD unk2; } MX_CAPABILITIES_EX;
typedef struct { BYTE BatteryType; BYTE BatteryLevel; } MX_BATTERY_INFORMATION;
typedef struct { WORD VirtualKey; WCHAR Unicode; WORD Flags; BYTE UserIndex; BYTE HidCode; } MX_KEYSTROKE;

#define XINPUT_GAMEPAD_GUIDE        0x0400
#define XINPUT_DEVTYPE_GAMEPAD      0x01
#define XINPUT_DEVSUBTYPE_GAMEPAD   0x01
#define XINPUT_CAPS_FFB_SUPPORTED   0x0001
#define BATTERY_DEVTYPE_GAMEPAD     0x00
#define BATTERY_TYPE_DISCONNECTED   0x00
#define BATTERY_TYPE_WIRED          0x01
#define BATTERY_LEVEL_FULL          0x03
#define XINPUT_KEYSTROKE_KEYDOWN    0x0001
#define XINPUT_KEYSTROKE_KEYUP      0x0002
#define XUSER_INDEX_ANY             0x000000FF

static mpad_shm *g_shm;
static LONG g_shm_probed;
static BOOL g_enabled = TRUE;
static WORD g_last_buttons[MPAD_SLOTS];

static mpad_shm *shm(void)
{
    if (!InterlockedCompareExchange(&g_shm_probed, 1, 0))
    {
        char buf[64];
        DWORD n = GetEnvironmentVariableA("MADEIRA_PAD_SHM", buf, sizeof(buf));
        if (n && n < sizeof(buf))
        {
            mpad_shm *p = (mpad_shm *)(ULONG_PTR)_strtoui64(buf, NULL, 16);
            if (p && p->magic == MPAD_MAGIC && p->version == MPAD_VERSION
                    && p->slot_count == MPAD_SLOTS && p->slot_size == sizeof(mpad_slot))
                g_shm = p;
        }
    }
    return g_shm;
}

static mpad_slot *slot(DWORD index)
{
    mpad_shm *s;
    if (index >= MPAD_SLOTS || !(s = shm()) || !s->slots[index].connected) return NULL;
    return &s->slots[index];
}

static DWORD get_state(DWORD index, MX_STATE *state, BOOL with_guide)
{
    mpad_slot *p;
    if (index >= MPAD_SLOTS || !state) return ERROR_BAD_ARGUMENTS;
    if (!(p = slot(index))) return ERROR_DEVICE_NOT_CONNECTED;
    memset(state, 0, sizeof(*state));
    state->dwPacketNumber = p->packet;
    if (!g_enabled) return ERROR_SUCCESS;       /* XInputEnable(FALSE): neutral state */
    state->Gamepad.wButtons = with_guide ? p->buttons : (WORD)(p->buttons & ~XINPUT_GAMEPAD_GUIDE);
    state->Gamepad.bLeftTrigger = p->left_trigger;
    state->Gamepad.bRightTrigger = p->right_trigger;
    state->Gamepad.sThumbLX = p->lx;
    state->Gamepad.sThumbLY = p->ly;
    state->Gamepad.sThumbRX = p->rx;
    state->Gamepad.sThumbRY = p->ry;
    return ERROR_SUCCESS;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(inst);
    return TRUE;
}

void WINAPI XInputEnable(BOOL enable)
{
    mpad_shm *s = shm();
    g_enabled = enable;
    if (!enable && s)
    {
        for (int i = 0; i < MPAD_SLOTS; i++)
        {
            s->slots[i].rumble_left = s->slots[i].rumble_right = 0;
            s->slots[i].rumble_seq++;
        }
    }
}

DWORD WINAPI XInputGetState(DWORD index, MX_STATE *state)
{
    return get_state(index, state, FALSE);
}

DWORD WINAPI XInputGetStateEx(DWORD index, MX_STATE *state)
{
    return get_state(index, state, TRUE);
}

DWORD WINAPI XInputSetState(DWORD index, MX_VIBRATION *vibration)
{
    mpad_slot *p;
    if (index >= MPAD_SLOTS || !vibration) return ERROR_BAD_ARGUMENTS;
    if (!(p = slot(index))) return ERROR_DEVICE_NOT_CONNECTED;
    if (g_enabled)
    {
        p->rumble_left = vibration->wLeftMotorSpeed;
        p->rumble_right = vibration->wRightMotorSpeed;
        p->rumble_seq++;
    }
    return ERROR_SUCCESS;
}

static void fill_caps(MX_CAPABILITIES *caps)
{
    memset(caps, 0, sizeof(*caps));
    caps->Type = XINPUT_DEVTYPE_GAMEPAD;
    caps->SubType = XINPUT_DEVSUBTYPE_GAMEPAD;
    caps->Flags = XINPUT_CAPS_FFB_SUPPORTED;
    caps->Gamepad.wButtons = 0xF3FF;            /* everything but guide + reserved */
    caps->Gamepad.bLeftTrigger = 0xFF;
    caps->Gamepad.bRightTrigger = 0xFF;
    caps->Gamepad.sThumbLX = (SHORT)0xFFC0;
    caps->Gamepad.sThumbLY = (SHORT)0xFFC0;
    caps->Gamepad.sThumbRX = (SHORT)0xFFC0;
    caps->Gamepad.sThumbRY = (SHORT)0xFFC0;
    caps->Vibration.wLeftMotorSpeed = 0xFF;
    caps->Vibration.wRightMotorSpeed = 0xFF;
}

DWORD WINAPI XInputGetCapabilities(DWORD index, DWORD flags, MX_CAPABILITIES *caps)
{
    if (index >= MPAD_SLOTS || !caps) return ERROR_BAD_ARGUMENTS;
    if (!slot(index)) return ERROR_DEVICE_NOT_CONNECTED;
    fill_caps(caps);
    return ERROR_SUCCESS;
}

DWORD WINAPI XInputGetCapabilitiesEx(DWORD unk, DWORD index, DWORD flags, MX_CAPABILITIES_EX *caps)
{
    if (index >= MPAD_SLOTS || !caps) return ERROR_BAD_ARGUMENTS;
    if (!slot(index)) return ERROR_DEVICE_NOT_CONNECTED;
    memset(caps, 0, sizeof(*caps));
    fill_caps(&caps->Capabilities);
    caps->VendorId = 0x045E;       /* Xbox Wireless Controller identity, which games expect */
    caps->ProductId = 0x02FD;
    caps->VersionNumber = 0x0408;
    return ERROR_SUCCESS;
}

DWORD WINAPI XInputGetBatteryInformation(DWORD index, BYTE type, MX_BATTERY_INFORMATION *info)
{
    mpad_slot *p;
    if (index >= MPAD_SLOTS || !info) return ERROR_BAD_ARGUMENTS;
    if (type != BATTERY_DEVTYPE_GAMEPAD)
    {
        info->BatteryType = BATTERY_TYPE_DISCONNECTED;
        info->BatteryLevel = 0;
        return ERROR_SUCCESS;
    }
    if (!(p = slot(index))) return ERROR_DEVICE_NOT_CONNECTED;
    info->BatteryType = p->battery_type ? p->battery_type : BATTERY_TYPE_WIRED;
    info->BatteryLevel = p->battery_type ? p->battery_level : BATTERY_LEVEL_FULL;
    return ERROR_SUCCESS;
}

/* Button edges as VK_PAD_* keystrokes, one per call, for games (and menus)
 * that poll XInputGetKeystroke instead of XInputGetState. */
static const struct { WORD mask; WORD vk; } key_map[] = {
    { 0x1000, 0x5800 }, { 0x2000, 0x5801 }, { 0x4000, 0x5802 }, { 0x8000, 0x5803 },
    { 0x0200, 0x5804 }, { 0x0100, 0x5805 },
    { 0x0001, 0x5810 }, { 0x0002, 0x5811 }, { 0x0004, 0x5812 }, { 0x0008, 0x5813 },
    { 0x0010, 0x5814 }, { 0x0020, 0x5815 }, { 0x0040, 0x5816 }, { 0x0080, 0x5817 },
};

DWORD WINAPI XInputGetKeystroke(DWORD index, DWORD reserved, MX_KEYSTROKE *ks)
{
    DWORD first = index == XUSER_INDEX_ANY ? 0 : index;
    DWORD last = index == XUSER_INDEX_ANY ? MPAD_SLOTS - 1 : index;
    BOOL any = FALSE;

    if (!ks || (index != XUSER_INDEX_ANY && index >= MPAD_SLOTS)) return ERROR_BAD_ARGUMENTS;
    for (DWORD i = first; i <= last; i++)
    {
        mpad_slot *p = slot(i);
        if (!p) continue;
        any = TRUE;
        WORD now = g_enabled ? p->buttons : 0;
        WORD changed = now ^ g_last_buttons[i];
        for (size_t k = 0; k < sizeof(key_map) / sizeof(key_map[0]); k++)
        {
            if (!(changed & key_map[k].mask)) continue;
            memset(ks, 0, sizeof(*ks));
            ks->VirtualKey = key_map[k].vk;
            ks->Flags = (now & key_map[k].mask) ? XINPUT_KEYSTROKE_KEYDOWN : XINPUT_KEYSTROKE_KEYUP;
            ks->UserIndex = (BYTE)i;
            g_last_buttons[i] ^= key_map[k].mask;
            return ERROR_SUCCESS;
        }
    }
    return any ? ERROR_EMPTY : ERROR_DEVICE_NOT_CONNECTED;
}

DWORD WINAPI XInputGetDSoundAudioDeviceGuids(DWORD index, GUID *render, GUID *capture)
{
    if (index >= MPAD_SLOTS || !render || !capture) return ERROR_BAD_ARGUMENTS;
    if (!slot(index)) return ERROR_DEVICE_NOT_CONNECTED;
    memset(render, 0, sizeof(*render));
    memset(capture, 0, sizeof(*capture));
    return ERROR_SUCCESS;
}

DWORD WINAPI XInputGetAudioDeviceIds(DWORD index, WCHAR *render, UINT *render_count, WCHAR *capture, UINT *capture_count)
{
    if (index >= MPAD_SLOTS) return ERROR_BAD_ARGUMENTS;
    if (!slot(index)) return ERROR_DEVICE_NOT_CONNECTED;
    if (render_count) *render_count = 0;
    if (capture_count) *capture_count = 0;
    return ERROR_SUCCESS;
}

DWORD WINAPI XInputWaitForGuideButton(DWORD index, DWORD flags, void *listen)
{
    return ERROR_NOT_SUPPORTED;
}

DWORD WINAPI XInputCancelGuideButtonWait(DWORD index)
{
    return ERROR_NOT_SUPPORTED;
}

DWORD WINAPI XInputPowerOffController(DWORD index)
{
    return index < MPAD_SLOTS ? ERROR_SUCCESS : ERROR_BAD_ARGUMENTS;
}

DWORD WINAPI XInputGetBaseBusInformation(DWORD index, void *info)
{
    return ERROR_NOT_SUPPORTED;
}
