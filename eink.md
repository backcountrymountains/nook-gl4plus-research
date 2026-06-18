# Nook Glowlight 4 Plus — E-Ink Refresh (EPD Controller)

## Overview

The GL4 Plus (bnrv1300, "Emperor" platform, Android 8.1) uses an AllWinner SoC with a
custom B&N AOSP. Getting GC16 waveform refreshes working in KOReader required finding the
actual kernel control point — three mechanisms were tried before the working one was found.

---

## What was tried and what failed

### 1. `Surface.einkChangeQuickUpdateMode` — does NOT reach the kernel driver

`com.nook.partner.EpdDisplayControllerImpl` calls this for full refresh (mode 5):

```java
// From decompiled EpdDisplayControllerImpl.java
SystemPropertiesProxy.set(context, "persist.mode.quick", Integer.toHexString(0x80000004));
SystemPropertiesProxy.set(context, "persist.mode.global", "0");
Surface.class.getDeclaredMethod("einkChangeQuickUpdateMode", Integer.TYPE)
    .invoke(Surface.class.newInstance(), 0x80000004);
```

From a non-system app (KOReader), `einkChangeQuickUpdateMode` fires without exception but
**does not change the kernel waveform mode**. Verified via dmesg — every page turn kept
showing `mode=0x200084` (GU16) regardless of how many times we called the method.

The system properties (`persist.mode.quick`, `persist.mode.global`) also can't be set from
a non-system app: `SystemProperties.set()` requires platform privileges.

### 2. `View.invalidate(int mode)` — fires but does not change kernel mode

B&N's custom AOSP adds a hidden `View.invalidate(int)` overload that routes the integer as
an EPD waveform hint. Used by B&N's reader for fast page turns:

```java
// B&N reader page turn: mapToUpdateMode(8) = 75497474 = DITHERING_SIMPLE | DU_MODE
View.class.getDeclaredMethod("invalidate", Integer.TYPE).invoke(view, 75497474);
```

We tried calling this with `mode=4` (GC16) and `mode=0x80000004` (GC16|NO_MERGE).
Logcat confirmed the calls landed (`Emperor EPD invalidate: driverMode=0x4`), but
dmesg showed no change — still `mode=0x200084` for every update.

**Root cause**: KOReader renders via `ANativeWindow` (direct buffer, not the Android View
draw cycle). The `View.invalidate(int)` waveform hint is only applied to the View's own
draw cycle. Because KOReader bypasses the View system, the hint never propagates to the
display driver for KOReader's frames.

### 3. `force_update_mode` sysfs (WORKING ✓)

The AllWinner display driver exposes a sysfs control node:

```
/sys/devices/virtual/disp/disp/waveform/force_update_mode
```

Writing an integer to this file forces the EPD waveform for the next display update.
Verified via dmesg:

```
# Before (default):
mode=0x200084  total=29  waveform_paddr=0x001af164   ← GU16 + GAMMA_CORRECT

# After: echo 4 > force_update_mode
mode=0x200004  total=29  waveform_paddr=0x00064b40   ← GC16 + GAMMA_CORRECT (different LUT!)
```

The waveform address change confirms a completely different LUT is being loaded for GC16.

---

## How the working implementation works

### Magisk module: `epd_gc16`

The sysfs node is `root:root rw-rw----` by default — world-inaccessible. A Magisk boot
script grants world-write permission once at startup:

**`/data/adb/modules/epd_gc16/service.sh`**:
```sh
EPD_MODE=/sys/devices/virtual/disp/disp/waveform/force_update_mode
i=0
while [ ! -e "$EPD_MODE" ] && [ $i -lt 20 ]; do sleep 1; i=$((i+1)); done
if [ -e "$EPD_MODE" ]; then
    chmod 666 "$EPD_MODE"
    echo 0 > "$EPD_MODE"
fi
```

Source in: `nook-gl4plus-research/magisk/epd_gc16/`

### `NookEmperorEPDController.kt`

```kotlin
private const val FORCE_UPDATE_MODE =
    "/sys/devices/virtual/disp/disp/waveform/force_update_mode"

override fun setEpdMode(targetView: View, mode: Int, ...) {
    val forceMode = if (mode == getWaveformFull()) EMPEROR_EINK_GC16_MODE else 0
    try {
        File(FORCE_UPDATE_MODE).writeText(forceMode.toString())
    } catch (e: IOException) {
        Log.w(TAG, "sysfs write failed (chmod 666 needed?): $e")
    }
}

override fun resume() {
    // Reset to 0 so partial refreshes use default GU16 after resume.
    try { File(FORCE_UPDATE_MODE).writeText("0") } catch (_: IOException) {}
}
```

---

## Waveform constants

From `sunxi-kobo.h` and decompiled `EpdDisplayControllerImpl.java`:

| Constant | Value | Kernel mode | Description |
|---|---|---|---|
| `EMPEROR_EINK_GC16_MODE` | `0x04` | `0x200004` | Full quality, 16-grey, slow flash |
| `EMPEROR_EINK_GU16_MODE` | `0x84` | `0x200084` | Partial, faster, some ghosting |
| `EMPEROR_EINK_NO_MERGE` | `0x80000000` | — | NO_MERGE flag (for `einkChangeQuickUpdateMode` only) |
| `EINK_GAMMA_CORRECT` | `0x200000` | — | Driver adds this automatically |

The driver always OR-s `EINK_GAMMA_CORRECT (0x200000)` into the mode value when presenting
to the EPD panel — visible in dmesg as the `0x200000` high bits.

---

## KOReader integration

### `getMode()` — `"full-only"`

`NookEmperorEPDController.getMode()` returns `"full-only"`. In `framebuffer_android.lua`
this means:

| Refresh path | EPD controller called? |
|---|---|
| `refreshFullImp` | Yes → `setEpdMode(getWaveformFull(), ...)` |
| `refreshPartialImp` | No — just `_updateWindow()` |
| `refreshUIImp` | No |
| `refreshFastImp` | No |

`"full-only"` was chosen because partial mode behavior with `"all"` has not been tested.
If `view.invalidate()` or sysfs partial-mode writes turn out to work cleanly, `"all"` could
be enabled to get GU16 waveform on partial updates too.

### KOReader full refresh rate setting

Stored in `settings.reader.lua` as `full_refresh_count`:
- `1` = Every page
- `6` = Every 6 pages (default)
- `0` = Never
- `-1` = Every chapter

`FULL_REFRESH_COUNT` is the live in-memory value (`UIManager.FULL_REFRESH_COUNT`);
`full_refresh_count` + `night_full_refresh_count` are the persisted keys.

### EPD factory routing

```kotlin
// EPDFactory.kt
DeviceInfo.Id.NOOK_GL4PLUS -> NookEmperorEPDController()
DeviceInfo.Id.NOOK_GL4     -> NGL4EPDController()
```

```kotlin
// DeviceInfo.kt
MANUFACTURER == "barnesandnoble" && MODEL == "bnrv1300" -> Id.NOOK_GL4PLUS
```

---

## Sysfs map for the AllWinner EPD driver

Full list of nodes in `/sys/devices/virtual/disp/disp/waveform/`:

| Node | Permissions | Notes |
|---|---|---|
| `force_update_mode` | `rw-rw----` (root:root) | Write waveform mode int (4=GC16, 0=default GU16) |
| `GC16_fresh_cnt` | `rw-rw----` | Counter of GC16 refreshes since boot |
| `force_region_update` | `rw-rw----` | Force update a specific screen region |
| `frame_ctrl` | `rw-rw----` | Frame control register |
| `wait_mode` | `rwxrwxrwx` | Wait mode for EPD updates (default=1) |
| `epd_pmic_power` | `rwxrwxrwx` | EPD PMIC power control |
| `vcom` | `rw-rw----` | VCOM voltage setting |
| `name` | `rw-rw----` | Waveform library name |
| `libversion` | `rw-rw----` | Waveform library version |

`/dev/disp` (AllWinner display ioctl device) is also present and **world-accessible**
(`crw-rw-rw-`), owned by `system:system`. This could be used as an alternative to sysfs
for EPD mode control via ioctl — not yet investigated.

---

## Testing procedure

### Confirm GC16 is active

After installing the Magisk module and our KOReader build:

1. Open KOReader → swipe from top → Screen → E-ink settings → Full refresh rate → Every page
2. Turn pages
3. Check dmesg:

```sh
adb shell dmesg | grep "order=" | tail -10
# Expected: mode=0x200004 (GC16)
# If still:  mode=0x200084 (GU16), the sysfs write isn't reaching the driver
```

4. Check logcat for the controller:
```sh
adb logcat -d | grep "Emperor EPD"
# Expected: Emperor EPD: force_update_mode=4 (waveform=0x80000004)
# If:        Emperor EPD: sysfs write failed ...  →  chmod 666 not applied
```

### Confirm GC16 is NOT active when "Never" is selected

With "Never" set, `setEpdMode` is never called, so `force_update_mode` stays at 0.
dmesg should show `mode=0x200084` (GU16, no flash) for all page turns.

### Check waveform file is accessible

```sh
adb shell ls -la /sys/devices/virtual/disp/disp/waveform/force_update_mode
# After Magisk boot script: should show -rw-rw-rw- (666)
# Before / without module:  -rw-rw---- (root:root only)
```

---

## History of investigation

1. Started from `github.com/koreader/koreader/issues/14574` — no EPD driver existed for bnrv1300
2. Decompiled `com.nook.partner.EpdDisplayControllerImpl` to understand B&N's approach
3. Implemented `Surface.einkChangeQuickUpdateMode` → fires but no kernel effect
4. Switched to `View.invalidate(4)` → fires but no kernel effect (ANativeWindow bypass)
5. Discovered AllWinner sysfs at `/sys/devices/virtual/disp/disp/waveform/`
6. Confirmed `force_update_mode=4` changes kernel mode to `0x200004` (GC16) via dmesg
7. Added Magisk module to chmod 666 the node on boot
8. KOReader now writes directly to sysfs in `setEpdMode`
