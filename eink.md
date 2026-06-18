# Nook Glowlight 4 Plus — E-Ink Refresh (EPD Controller)

## Overview

The GL4 Plus (bnrv1300, "Emperor" platform, Android 8.1) uses an AllWinner SoC with a
custom B&N AOSP. Getting GC16 waveform refreshes working in KOReader required finding the
actual kernel control point — three mechanisms were tried before the working one was found.

---

## Baseline

The AllWinner EPD driver defaults to **GU16 (`mode=0x200084`)** for all display updates.
KOReader renders via `ANativeWindow` (direct buffer, bypassing the Android View draw cycle),
so B&N's `View.invalidate(int)` waveform hints never reach the driver for KOReader's frames.
This is why GC16 never worked before: there was no path for a non-system app using
`ANativeWindow` to force a different waveform.

---

## What was tried

### 1. `Surface.einkChangeQuickUpdateMode` — no kernel effect

Called without exception from KOReader but dmesg showed every update still at `mode=0x200084`
(GU16). `SystemProperties.set()` for `persist.mode.quick`/`persist.mode.global` also requires
platform privileges — unavailable to a non-system app.

### 2. `View.invalidate(int mode)` — no kernel effect

Logcat confirmed calls landed (`Emperor EPD invalidate: driverMode=0x4`), but dmesg showed
no change. Root cause: `sunxihwc_eink` only processes waveform hints for frames flowing
through the View draw cycle. KOReader's `ANativeWindow` frames bypass that path entirely.
Confirmed in [koreader/koreader#11110](https://github.com/koreader/koreader/issues/11110).

### 3. `force_update_mode` sysfs (WORKING ✓)

```
/sys/devices/virtual/disp/disp/waveform/force_update_mode
```

Writing an integer forces the EPD waveform for the next display update:

```
# Before: echo 0 > force_update_mode
mode=0x200084  waveform_paddr=0x001af164  ← GU16

# After:  echo 4 > force_update_mode
mode=0x200004  waveform_paddr=0x00064b40  ← GC16 (different LUT)
```

### 4. `com.nook.action.full_refresh` broadcast — wrong frame

ADB broadcast confirmed working on bnrv1300:
```sh
adb shell am broadcast -p com.nook.partner -a com.nook.action.full_refresh
```
Produced `mode=0x80200004` in dmesg. Cold-start latency: ~7s. Warm: ~160ms.

Integrated into `NookEmperorEPDController.setEpdMode` and tested with "full refresh every
page." Result: GC16 always flashed the **OLD page** before the new page appeared.

Root cause: `einkChangeQuickUpdateMode` forces GC16 of what the EPD hardware is **currently
displaying**, not the next queued buffer. `setEpdMode` is called after
`ANativeWindow_unlockAndPost`, but the EPD is still mid-GU16 waveform on the previous page
(~260ms). The broadcast fires ~160ms later onto that in-progress waveform.

This is fundamentally different from the sysfs approach: `force_update_mode=4` is a driver
flag read when the next queued buffer is processed, so it correctly arms GC16 for the
*incoming* page. No timing fix exists — the broadcast works as a standalone "clean the screen"
command but is architecturally incompatible with per-page-turn GC16.

---

## Working implementation

### Magisk module: `epd_gc16`

The sysfs node has three access control layers that must all be resolved:

1. **DAC permissions**: `root:root rw-rw----` by default — `service.sh` runs `chmod 666` at boot.
2. **SELinux type enforcement**: allow rule for `untrusted_app` to write the node.
3. **SELinux MLS constraint**: the target type must carry `mlstrustedobject`, OR source and
   target MLS levels must match. `sysfs_leds` lacks this attribute by default, so the constraint
   blocks writes even when an allow rule exists. `typeattribute sysfs_leds mlstrustedobject` fixes it.

All SELinux rules are applied via `magiskpolicy --live` after `boot_completed=1`. `sepolicy.rule`
is intentionally empty — Magisk 24.2's compiled-policy patcher only reliably handles the bare
`sysfs` type; rules for subtypes must be applied live to survive Android init's `restorecon`.

**`/data/adb/modules/epd_gc16/service.sh`** (confirmed working on clean reboot):
```sh
EPD_MODE=/sys/devices/virtual/disp/disp/waveform/force_update_mode

# Phase 1: chmod (root can write sysfs regardless of SELinux type)
i=0
while [ ! -e "$EPD_MODE" ] && [ $i -lt 20 ]; do sleep 1; i=$((i+1)); done
if [ -e "$EPD_MODE" ]; then
    chmod 666 "$EPD_MODE"
    echo 0 > "$EPD_MODE"
fi

# Phase 2: after boot_completed (post-restorecon), apply SELinux rules then relabel
(
    i=0
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 120 ]; do
        sleep 1; i=$((i+1))
    done
    if [ -e "$EPD_MODE" ]; then
        magiskpolicy --live "typeattribute sysfs_leds mlstrustedobject"
        magiskpolicy --live "allow untrusted_app sysfs_leds file { getattr open write }"
        chcon u:object_r:sysfs_leds:s0 "$EPD_MODE"
    fi
) &
```

Phase 2 ordering is critical: `typeattribute` must come before the `allow` rule (MLS constraint
is checked before type enforcement). `chcon` must come last (relabels the node under the new
policy). All three must run after `boot_completed=1` — init's `restorecon` resets any earlier
`chcon`, and no further policy reload occurs after that point.

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
    // Reset so partial refreshes use GU16 default after resume.
    try { File(FORCE_UPDATE_MODE).writeText("0") } catch (_: IOException) {}
}
```

---

## Waveform constants

From `sunxi-kobo.h`, decompiled `EpdDisplayControllerImpl.java`, and
[koreader/koreader#11110](https://github.com/koreader/koreader/issues/11110). Constants
marked ✓ confirmed by name+value match between Nook decompile and `sunxi_kobo_h.lua`.

| Constant | Value | Kernel mode | Description |
|---|---|---|---|
| `EINK_GC16_MODE` ✓ | `0x04` | `0x200004` | Full quality, 16-grey, slow flash |
| `EINK_GU16_MODE` ✓ | `0x84` | `0x200084` | Partial, faster, some ghosting |
| `EINK_DU_MODE` ✓ | — | — | Direct update (2-level, fastest) |
| `EINK_A2_MODE` ✓ | — | — | 2-level animation mode |
| `EINK_GL16_MODE` ✓ | — | — | GL16 waveform |
| `EINK_GLR16_MODE` ✓ | — | — | GLR16 (REAGL) waveform |
| `EINK_GLD16_MODE` ✓ | — | — | GLD16 (REAGLD) waveform |
| `EINK_GC4_MODE` ✓ | — | — | GC4 waveform |
| `EINK_INIT_MODE` ✓ | — | — | Full init waveform |
| `EINK_MONOCHROME` ✓ | — | — | Monochrome rendering |
| `EINK_DITHERING_SIMPLE` ✓ | — | — | Simple dithering |
| `EINK_DITHERING_Y1` ✓ | — | — | Y1 dithering |
| `EINK_DITHERING_Y4` ✓ | — | — | Y4 dithering |
| `EINK_DITHERING_NTX_Y1` ✓ | — | — | NTX Y1 dithering |
| `EINK_AUTO_MODE` | `0x8000` | — | Runtime waveform selection by driver |
| `EINK_RECT_MODE` / `EINK_PARTIAL_MODE` | `1024` | — | Partial region update mode |
| `EINK_RUBBER_MODE` / `EINK_CLEAR_MODE` | `136` | — | Clear/rubber waveform |
| `EINK_NO_MERGE` | `0x80000000` | — | Bypass broken collision/damage handling |
| `EINK_GAMMA_CORRECT` ✓ | `0x200000` | — | Driver adds this automatically |
| `UI_FULL_REFRESH` | `0x80000004` | `0x200004` | `EINK_NO_MERGE \| EINK_GC16_MODE`; B&N's full redraw constant |

The driver always OR-s `EINK_GAMMA_CORRECT (0x200000)` into the mode value.
`EINK_NO_MERGE` bypasses AllWinner HWC collision/damage merging (described by NiLuJe as
"hilariously broken" — refresh requests can be silently optimized away without it). B&N
always uses it for full refreshes.

---

## force_update_mode sysfs constraints

The `force_update_mode` node is a simple waveform selector register, not a full mode word.
Experimentally confirmed constraints:

- **Accepted values only**: The sysfs store handler validates `val >= 0` after parsing.
  Any value with the MSB set (e.g. `EINK_NO_MERGE | EINK_GC16_MODE = 0x80000004`) is
  rejected with `ERANGE`. Writing the signed decimal `-2147483644` is also rejected —
  the driver does not accept negative values regardless of encoding.
- **Only base waveform indices work**: flag bits (`EINK_NO_MERGE`, `EINK_GAMMA_CORRECT`,
  etc.) cannot be set through this node.

Results of all waveforms tested via this node:

| Value | Write accepted? | Result |
|---|---|---|
| `0` | ✓ | Resets to driver default (GU16) |
| `0x04` (GC16) | ✓ | Clean full refresh — in use |
| `0x84` (GU16) | ✓ | Identical to default; redundant |
| `0x02` (DU) | ✓ | Updates occur but destroy anti-aliasing — unusable for text |
| `0x40` (GLR16/REAGL) | ✓ | Write accepted, driver silently ignores it; no screen update |
| `0x80000004` (GC16 + NO_MERGE) | ✗ ERANGE | MSB rejected |

**Conclusion**: GC16 (`0x04`) for full refresh and GU16 default (`0`) for all other modes
is the optimal and complete configuration for this device through the sysfs path.
GLR16 is supported on the NGL4 via the `View.invalidate()` / HWC pipeline — a path
unavailable to KOReader's `ANativeWindow` rendering.

### KOReader "fast" refresh path

KOReader's `"fast"` waveform mode (used during scrolling) never fires in practice on
this device. UIManager coalesces refresh requests by priority (`fast=2 < ui=3`), so any
`"fast"` request that overlaps with a `"ui"` request in the same frame is silently
upgraded to `"ui"`. Since e-ink menus avoid momentum scrolling, the `"fast"` path
has no reachable trigger in normal KOReader usage on the GL4+.

---

## KOReader integration

### `getMode()` — `"all"`

`NookEmperorEPDController.getMode()` returns `"all"`:

| Refresh path | `setEpdMode` called? | sysfs write |
|---|---|---|
| `refreshFullImp` | Yes | `4` (GC16) |
| `refreshPartialImp` | Yes | `0` (GU16 default) |
| `refreshUIImp` | Yes | `0` (GU16 default) |
| `refreshFastImp` | Yes | `0` (GU16 default) |

`force_update_mode` is persistent kernel state. With `"full-only"`, partial refreshes, UI
redraws, and clock ticks all fire as GC16 until `resume()` runs — observed as ~50-second
periodic flashing after the first page turn. `"all"` resets to `0` before each non-full
refresh, correctly scoping the mode to each individual update.

### KOReader full refresh rate setting

`full_refresh_count` in `settings.reader.lua`: `1` = Every page, `6` = Every 6 pages
(default), `0` = Never, `-1` = Every chapter.

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

## Security: SELinux access control

Getting `force_update_mode` writable from an unprivileged app requires bypassing two layers:

1. **DAC**: `chmod 666` — straightforward.
2. **SELinux**: both type enforcement AND the MLS constraint must pass. `sysfs_leds` lacks
   `mlstrustedobject` by default, so `allow untrusted_app sysfs_leds file write` alone is
   insufficient — the MLS constraint rejects the write first. `typeattribute sysfs_leds mlstrustedobject`
   satisfies the constraint.

The production module uses `sysfs_leds` (1 labeled node on this device after our `chcon`:
`force_update_mode` itself). This limits blast radius vs. the broad `sysfs` rule, which would
grant any installed app write access to all unlabeled sysfs nodes — CPU governor, thermal
thresholds, battery controls, etc. — without any Android permission prompt.

AVC denials confirmed on device (all three blocked before the fix):
```
avc: denied { getattr } for name="force_update_mode"
  scontext=u:r:untrusted_app:s0  tcontext=u:object_r:sysfs_leds:s0  permissive=0
avc: denied { open }    ...
avc: denied { write }   ...
```

---

## Dead end: `/dev/disp` ioctl

`/dev/disp` is world-accessible (`crw-rw-rw-`) but has no EPD ioctls — it covers LCD/HDMI/
layer/video commands only. EPD waveform selection lives exclusively in the sysfs waveform
nodes. Also explicitly deprecated upstream by linux-sunxi.

---

## Sysfs map

Nodes in `/sys/devices/virtual/disp/disp/waveform/`:

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

---

## Testing procedure

### Confirm GC16 is active

1. KOReader → swipe from top → Screen → E-ink settings → Full refresh rate → Every page
2. Turn pages
3. Check dmesg:
```sh
adb shell dmesg | grep "order=" | tail -10
# Expected: mode=0x200004 (GC16)
# If still:  mode=0x200084 (GU16), the sysfs write isn't reaching the driver
```
4. Check logcat:
```sh
adb logcat -d | grep "Emperor EPD"
# Expected: Emperor EPD: force_update_mode=4 (waveform=0x80000004)
# If:        Emperor EPD: sysfs write failed ...  →  chmod 666 not applied
```

### Confirm GC16 disabled with "Never"

`force_update_mode` stays at 0. dmesg should show `mode=0x200084` (GU16) for all page turns.

### Check node accessibility

```sh
adb shell ls -la /sys/devices/virtual/disp/disp/waveform/force_update_mode
# After Magisk: -rw-rw-rw- (666)
# Without:      -rw-rw---- (root:root only)
```

---

## EPD control comparison

| Scenario | Waveform | Mechanism | Root? |
|---|---|---|---|
| Stock KOReader (pre-change) | GU16 always | Driver default, no controller | No |
| Our changes, no root | GU16 always | sysfs write fails silently | No |
| Our changes, with root | GC16 for full refreshes | Magisk chmod + sysfs write | Yes |
| Nook e-reader app | GC16/GU16 per-refresh | View hints through HWC pipeline | No (system app) |
| Broadcast intent | GC16 (always wrong frame) | Partner service; flashes old page | No |
