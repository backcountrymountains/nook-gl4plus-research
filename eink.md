# Nook Glowlight 4 Plus — E-Ink Refresh (EPD Controller)

## Overview

The GL4 Plus (bnrv1300, "Emperor" platform, Android 8.1) uses an AllWinner SoC with a
custom B&N AOSP. Getting GC16 waveform refreshes working in KOReader required finding the
actual kernel control point — three mechanisms were tried before the working one was found.

---

## Baseline: what controls the screen without any EPD controller code

The AllWinner EPD driver has its own internal waveform selection logic and defaults to
**GU16 (`mode=0x200084`)** for all display updates when nothing overrides it.

When KOReader writes pixels via `ANativeWindow`, the display compositor passes those buffers
directly to the AllWinner driver, which picks a waveform autonomously. This is why the
failed approaches below didn't cause crashes or visible errors — they were no-ops layered on
top of a driver that was already refreshing the screen with GU16 defaults.

**B&N's own reader** works differently: it runs as a system app with platform privileges,
uses the Android View draw cycle, and calls `View.invalidate(int)` or sets `SystemProperties`
to hint the waveform. That hint propagates through the View compositor path to the driver.
KOReader bypasses that entire path, so the hints never arrive — but the driver still refreshes
using its own GU16 default.

This is why GC16 never worked in KOReader before our sysfs approach: there was no path for a
non-system app using `ANativeWindow` to force a different waveform. The filing of
[koreader/koreader#14574](https://github.com/koreader/koreader/issues/14574) was the result
— full refreshes showed no flash because the driver always used GU16.

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
draw cycle). The `View.invalidate(int)` waveform hint is processed by `sunxihwc_eink` —
the AllWinner Hardware Composer for e-ink — but only for frames that flow through the
View draw cycle. KOReader's `ANativeWindow` frames bypass the View system entirely, so
`sunxihwc_eink` never sees the hint for KOReader's frames.

This was confirmed in [koreader/koreader#11110](https://github.com/koreader/koreader/issues/11110):
`View.invalidate(-2147483644)` (GC16|NO_MERGE) DOES produce `refreshMode= NO_MERGE GC16_MODE`
in logcat when called from the TestActivity (which uses a view hierarchy), but the same call
from KOReader's native activity produces only `refreshMode= GU16_MODE`.

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

### 4. `com.nook.action.full_refresh` broadcast intent — potential no-root path (untested for KOReader)

Discovered in [koreader/koreader#11110](https://github.com/koreader/koreader/issues/11110).
`com.nook.partner` exposes a broadcast intent that triggers a full GC16 refresh:

```sh
adb shell am broadcast -p com.nook.partner -a com.nook.action.full_refresh
```

Internally `com.nook.partner` (a system app with platform privileges) handles the intent by calling:
```java
SystemPropertiesProxy.set(context, "persist.mode.quick", Integer.toHexString(0x80000004));
Surface.einkChangeQuickUpdateMode(-2147483644);  // EINK_NO_MERGE | EINK_GC16_MODE
```

Because the handler runs inside the system app's process, `SystemProperties.set()` succeeds
and the call propagates through `sunxihwc_eink` to produce a GC16 commit — no root required.

KOReader could trigger this via:
```kotlin
context.sendBroadcast(
    Intent("com.nook.action.full_refresh").setPackage("com.nook.partner")
)
```

**Testing procedure:**

1. Confirm bnrv1300 support via ADB first (confirmed on bnrv1000/1100 only — bnrv1300 untested):
   ```sh
   adb shell am broadcast -p com.nook.partner -a com.nook.action.full_refresh
   adb logcat -d | grep "sunxihwc_eink"   # expect: refreshMode= NO_MERGE GC16_MODE
   adb shell dmesg | grep "mode=0x2000"   # expect: mode=0x200004
   ```
2. Add a temporary broadcast path in `NookEmperorEPDController.setEpdMode` and use
   "Full refresh rate → Every page" to trigger it on every page turn. Observe:
   - Does the GC16 flash show the new page or the previous one?
   - Does it double-flash (GU16 then GC16)?
   - Do dmesg timestamps show `mode=0x200004` before or after the ANativeWindow commit?
3. Try deliberate delays (50ms, 150ms, 250ms) between render and broadcast send to probe
   whether there is any window where ordering works correctly.

**Concerns:**

1. **The race condition is structural.** The sysfs approach is synchronous: write `4` →
   `ANativeWindow` commits → HWC picks up forced mode → GC16. The broadcast is async:
   `sendBroadcast` → Android routes to `com.nook.partner` → service wakes → calls
   `einkChangeQuickUpdateMode`. That dispatch chain takes ~160ms based on issue #11110
   logcat timestamps. KOReader's `ANativeWindow` frame has almost certainly already been
   committed with GU16 before the handler fires.

2. **Which frame does GC16 flash?** `einkChangeQuickUpdateMode` may either (a) set a flag
   for the next natural compositor commit, or (b) force an immediate refresh of whatever is
   currently in the framebuffer. If (a), by the time the flag is set, KOReader's frame is
   gone and the next compositor event (a UI update, a clock tick) gets GC16 instead. If (b),
   it flashes a stale frame. Neither reliably lands on the new page KOReader just rendered.

3. **The 2× GU16 before GC16 pattern.** Issue #11110 logcat showed this consistently even
   from the TestActivity (which has a view hierarchy and tight synchronization). GC16 doesn't
   arrive on the first compositor commit after the call — it takes at least two cycles. For
   KOReader's detached ANativeWindow path this is likely worse.

4. **Double-flash risk.** Even in the best case the sequence may be: KOReader commits frame
   → GU16 commit → broadcast lands → GC16 commit of the same frame. The user sees two
   refreshes per page turn.

5. **Silent failure.** Broadcast delivery is fire-and-forget. If `com.nook.partner` is
   stopped, crashed, or B&N renames the intent in a firmware update, nothing happens and
   there is no way to detect or fall back.

6. **Harder to justify upstream than sysfs.** A sysfs write with a graceful `IOException`
   fallback is straightforward to reason about. A dependency on a proprietary B&N service
   being alive is a harder argument to make to upstream maintainers — even though sysfs
   requires root and the broadcast does not.

**Bottom line:** worth one ADB test to confirm bnrv1300 support, but unlikely to work
correctly in KOReader's rendering path without solving the timing problem — and the async
dispatch latency may make a clean solution impossible.

---

## How the working implementation works

### Magisk module: `epd_gc16`

The sysfs node has two layers of access control that must both be resolved:

1. **DAC permissions**: `root:root rw-rw----` by default — `service.sh` runs `chmod 666` at boot.
2. **SELinux**: even with `chmod 666`, Android's mandatory access control blocks writes from
   `untrusted_app` context (`u:r:untrusted_app`) to `sysfs`-typed nodes (`u:object_r:sysfs`).
   A `sepolicy.rule` in the module adds the necessary allow rule at boot.

The AVC denial (confirmed on device before the fix):
```
avc: denied { write } for name="force_update_mode"
  scontext=u:r:untrusted_app:s0  tcontext=u:object_r:sysfs:s0  permissive=0
```

**`/data/adb/modules/epd_gc16/sepolicy.rule`**:
```
allow untrusted_app sysfs file { open read write getattr }
```

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

**Security note:** the `sepolicy.rule` is intentionally broad — it allows all `untrusted_app`
processes to open, read, write, and stat any sysfs node carrying the default `sysfs` label,
not just the EPD waveform node.

**Two targeted approaches were attempted and failed:**

1. **Custom type (`epd_waveform_node`)**: Magisk 24.2 `sepolicy.rule` does not support full
   `type` declarations with filesystem attributes. The `chcon` fell back to `unlabeled:s0`
   and the sysfs `associate` permission check rejected it.

2. **Borrowed type (`sysfs_vibrator`)**: The GL4+ has no vibrator hardware, so
   `sysfs_vibrator` has zero labeled nodes on the device — an ideal candidate. `chcon
   u:object_r:sysfs_vibrator:s0` succeeded (the kernel recognizes the type), but Magisk's
   policy patcher could not apply `allow untrusted_app sysfs_vibrator file { ... }` at
   either boot time or via `--live`. AVC denials persisted after both methods returned exit 0.
   Root cause: Magisk 24.2 cannot resolve `sysfs_vibrator` in the compiled binary policy
   when applying allow rules, even though the kernel uses the type correctly for labeling.

The vendor SELinux policy files were pulled and analyzed. Unused sysfs types confirmed on
device (zero labeled nodes): `sysfs_vibrator`, `sysfs_nfc_power_writable`, `sysfs_uio`.
Types with active nodes: `sysfs_zram` (74), `sysfs_zram_uevent` (1), `sysfs_debugfs_swsync`
(1), `sysfs_cma_readable` (1).

The broad `sysfs` rule is the only working solution with Magisk 24.2 on this device.
The incremental security reduction over an already-rooted device is limited in practice.

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

From `sunxi-kobo.h`, decompiled `EpdDisplayControllerImpl.java`, and
[koreader/koreader#11110](https://github.com/koreader/koreader/issues/11110). Constants
marked ✓ were confirmed by name+value match between the Nook decompile and `sunxi_kobo_h.lua`.

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

The driver always OR-s `EINK_GAMMA_CORRECT (0x200000)` into the mode value when presenting
to the EPD panel — visible in dmesg as the `0x200000` high bits.

`EINK_NO_MERGE` (`Integer.MIN_VALUE` in Java) bypasses the AllWinner HWC collision/damage
merging logic, which is described by NiLuJe as "hilariously broken" — refresh requests can
be silently "optimized" away without it. B&N always uses it for full refreshes.

`EINK_AUTO_MODE` is `0x8000` on both Nook and Kobo/sunxi. The value `5` seen in some
contexts is GL16 on mxcfb NTX kernels (a different SoC family) and was a misidentification.

---

## KOReader integration

### `getMode()` — `"all"`

`NookEmperorEPDController.getMode()` returns `"all"`. In `framebuffer_android.lua` this
means `setEpdMode` is called for every refresh type:

| Refresh path | `setEpdMode` called? | sysfs write |
|---|---|---|
| `refreshFullImp` | Yes | `4` (GC16) |
| `refreshPartialImp` | Yes | `0` (GU16 default) |
| `refreshUIImp` | Yes | `0` (GU16 default) |
| `refreshFastImp` | Yes | `0` (GU16 default) |

**Why `"all"` and not `"full-only"`**: `force_update_mode` is a persistent kernel state —
once written, it applies to every subsequent display commit until explicitly reset. With
`"full-only"`, `setEpdMode` is only called for full refreshes. After a full refresh writes
`4` (GC16), partial refreshes, UI redraws, and clock ticks all hit the driver while
`force_update_mode` is still `4`, causing spurious GC16 flashes on every display update
until KOReader is closed or `resume()` fires.

With `"all"`, every partial/UI/fast refresh calls `setEpdMode` with a non-full mode, which
writes `0` back before that commit. The mode is correctly scoped to each individual refresh.

This was discovered by observing ~50-second periodic flashing on the device after the first
page turn — confirmed in dmesg as GC16 commits (`mode=0x200004`) that did not correspond to
any user input.

**A reviewer of the upstream PR noted:** *"It should be 'all' if the partial modes you
implemented are working in the KOReader GUI."* This is now confirmed — `"all"` is correct
and `"full-only"` produces the spurious-flash bug described above.

**No-root note:** for upstream merging, the controller degrades gracefully without the
Magisk module — all sysfs writes fail silently with `IOException` and the driver uses its
GU16 default for every refresh. The broadcast intent (`com.nook.action.full_refresh`) is
the only known no-root candidate for full GC16 refreshes but is untested in KOReader's
rendering path — see "What was tried" section 4.

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

## Security implications of the Magisk module

### Two access control layers

Getting `force_update_mode` writable from an unprivileged app requires bypassing two
independent layers:

1. **DAC (file permissions)**: `chmod 666` in `service.sh` — straightforward.
2. **SELinux MAC**: the node carries `u:object_r:sysfs:s0` and Android blocks
   `untrusted_app` from writing `sysfs`-labeled files. `chmod 666` alone is not enough;
   SELinux enforces on top of DAC regardless of file mode bits.

The AVC denial confirmed on device before the fix:
```
avc: denied { write } for name="force_update_mode"
  scontext=u:r:untrusted_app:s0  tcontext=u:object_r:sysfs:s0  permissive=0
```

### The working rule and why it's broad

```
allow untrusted_app sysfs file { open read write getattr }
```

This grants every installed app the ability to open, read, write, and stat **any** sysfs
node carrying the default `sysfs` label — not just the EPD waveform node. On Android 8.1
that includes CPU frequency/governor nodes, thermal throttling thresholds, battery and
charging control nodes, and other hardware registers that haven't been given a more specific
SELinux type by the vendor.

A malicious app could silently manipulate these without any Android permission prompt, since
sysfs access is not part of the Android permission model.

### Targeted approaches that were attempted and failed

The ideal fix is to label only `force_update_mode` with a dedicated type and allow only
that type. Two approaches were tried:

**1. Custom type (`epd_waveform_node`)**

```
# sepolicy.rule
type epd_waveform_node fs_type sysfs_type
allow untrusted_app epd_waveform_node file { open read write getattr }
```

Magisk 24.2 `sepolicy.rule` does not support full `type` declarations with filesystem
attributes. `chcon u:object_r:epd_waveform_node:s0` failed — the kernel reported
`scontext=u:object_r:unlabeled:s0` in the AVC denial, meaning the type wasn't registered.
The sysfs filesystem `associate` permission check then rejected the relabeling.

**2. Borrowing `sysfs_vibrator`**

The GL4+ has no vibrator hardware, so `sysfs_vibrator` has zero labeled nodes on the device.
Confirmed by scanning all sysfs nodes on the live device:

| Type | Labeled nodes |
|---|---|
| `sysfs_vibrator` | 0 — no vibrator hardware |
| `sysfs_nfc_power_writable` | 0 — no NFC hardware |
| `sysfs_uio` | 0 — no UIO devices |
| `sysfs_zram` | 74 — in active use |
| `sysfs_zram_uevent` | 1 — in active use |
| `sysfs_debugfs_swsync` | 1 — in active use |
| `sysfs_cma_readable` | 1 — in active use |

`chcon u:object_r:sysfs_vibrator:s0` succeeded — the kernel recognizes the type and the
node was correctly relabeled. However, Magisk 24.2 could not apply
`allow untrusted_app sysfs_vibrator file { ... }` at either boot time (via `sepolicy.rule`)
or at runtime (via `magiskpolicy --live`). Both returned exit 0 but AVC denials persisted.
Root cause: Magisk's policy patcher cannot resolve `sysfs_vibrator` as an allow-rule target
in the compiled binary policy, even though the kernel uses the type correctly for labeling.

### Conclusion

The broad `sysfs` rule is the only working solution with Magisk 24.2 on this device. The
security trade-off is real but bounded in practice:

- The device is personal, single-user, and already rooted with Magisk — the security bar is
  already significantly lowered by the presence of root itself.
- The rule allows any installed app to write arbitrary sysfs nodes. On this device the
  practical impact is limited to display, battery, and thermal manipulation — annoying but
  not a data exfiltration risk.
- A future Magisk version that can apply allow rules for platform-defined sysfs subtypes
  would allow the `sysfs_vibrator` approach to be revisited without any code changes —
  only the `sepolicy.rule` and `service.sh` files need updating.

---

## Dead end: `/dev/disp` ioctl (no EPD waveform control)

`/dev/disp` is world-accessible (`crw-rw-rw-`, `system:system`) and was considered as a
no-root alternative to sysfs. Investigation via
[linux-sunxi.org/Sunxi_disp_driver_interface](https://linux-sunxi.org/Sunxi_disp_driver_interface)
ruled it out:

1. **No EPD ioctls.** The stable Sunxi disp ioctl list covers LCD, HDMI, layer, and video
   commands only. EPD waveform selection (`force_update_mode`, GC16/GU16) is a B&N/AllWinner
   extension that lives exclusively in the sysfs waveform nodes — `/dev/disp` has no concept
   of waveform mode.

2. **Explicitly deprecated upstream.** The linux-sunxi project states:
   > "The /dev/disp interface will break and will in the end vanish completely!"
   Building on it would be fragile regardless.

**Conclusion:** `/dev/disp` is a dead end for waveform control. Without the Magisk
`chmod 666`, `force_update_mode` is `rw-rw----` (root:root) and all sysfs writes fail
silently. The only remaining no-root candidate is the `com.nook.action.full_refresh`
broadcast intent — see "What was tried" section 4.

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

## EPD control comparison

### Before our changes — stock KOReader on GL4+

KOReader had no device entry for bnrv1300. It fell through to a generic Android path with
no EPD controller. It rendered via `ANativeWindow` (direct buffer writes), which flows to
`sunxihwc_eink` and then to the EPD driver. With no controller providing any input, the
driver used its **GU16 default for every refresh** — including KOReader's "full refresh"
events. No flash, some ghosting. This is what prompted
[koreader/koreader#14574](https://github.com/koreader/koreader/issues/14574).

### Our changes, without root

We added bnrv1300 detection and `NookEmperorEPDController`. On every full refresh,
`setEpdMode` tries to write `4` (GC16) to the sysfs node. Without the Magisk module, the
node is `rw-rw----` (root:root), so the write gets `IOException`, is caught silently, and
nothing changes. The driver still uses GU16 for everything.

The difference from before is structural only: the device is properly detected, the
controller is wired in, and the full-refresh path attempts waveform control. **The visual
result is identical to pre-change — GU16 for all refreshes.**

### Our changes, with root (Magisk `epd_gc16`)

The Magisk boot script `chmod 666`s the sysfs node. `setEpdMode` now succeeds: the
controller writes `4` before each full refresh, the driver picks up the forced mode, and the
commit goes out as **GC16** — the full 16-grey flash. After resume, the controller writes
`0` to reset to GU16 so partial refreshes continue using the driver's own selection.

### The Nook e-reader app

The Nook app takes a completely different architectural path. Because it is a system app
with platform privileges, it renders through the Android View draw cycle and calls
`View.invalidate(EINK_NO_MERGE | EINK_GC16_MODE)`. `sunxihwc_eink` sees the waveform hint
attached to each frame as it is committed — no root, no sysfs, no special permissions
beyond being a system app:

```
Nook app  →  View.invalidate(0x80000004)
                 ↓
             sunxihwc_eink HWC  ← hint arrives here (View draw cycle)
                 ↓
             EPD driver → GC16 commit
```

It can also call `Surface.einkChangeQuickUpdateMode(0x80000004)` and set
`SystemProperties` directly — both require platform privileges. The
`com.nook.action.full_refresh` broadcast intent wraps this same call so any app can
request a full GC16 refresh by letting the partner service exercise its own privileges.

KOReader's `ANativeWindow` path bypasses the View draw cycle entirely, so `sunxihwc_eink`
never sees a waveform hint for KOReader's frames regardless of what the EPD controller calls.

### Side-by-side

| Scenario | Waveform | Mechanism | Root? |
|---|---|---|---|
| Stock KOReader (pre-change) | GU16 always | Driver default, no controller | No |
| Our changes, no root | GU16 always | sysfs write fails silently | No |
| Our changes, with root | GC16 for full refreshes | Magisk chmod + sysfs write | Yes |
| Nook e-reader app | GC16/GU16 per-refresh | View hints through HWC pipeline | No (system app) |
| Broadcast intent (untested) | GC16 for full refresh | Partner service uses system privileges | No |

---

## History of investigation

1. Started from [koreader/koreader#14574](https://github.com/koreader/koreader/issues/14574) — no EPD driver existed for bnrv1300
2. Decompiled `com.nook.partner.EpdDisplayControllerImpl` to understand B&N's approach
3. Implemented `Surface.einkChangeQuickUpdateMode` → fires but no kernel effect
4. Switched to `View.invalidate(4)` → fires but no kernel effect (ANativeWindow bypass)
5. Discovered AllWinner sysfs at `/sys/devices/virtual/disp/disp/waveform/`
6. Confirmed `force_update_mode=4` changes kernel mode to `0x200004` (GC16) via dmesg
7. Added Magisk module to chmod 666 the node on boot
8. KOReader now writes directly to sysfs in `setEpdMode`
9. Discovered SELinux blocks sysfs writes from `untrusted_app` even with `chmod 666` —
   added `sepolicy.rule` to Magisk module; confirmed GC16 (`mode=0x200004`) in dmesg on
   live device with page-turn test
10. Discovered `"full-only"` mode causes spurious GC16 flashing — `force_update_mode` is
    persistent kernel state; after a full refresh sets it to `4`, every subsequent display
    commit (clock, UI, partial) also uses GC16 until explicitly reset; fixed by switching
    to `"all"` mode so every partial/UI/fast refresh resets to `0`; confirmed: full refresh
    flashes on every page, every-6-pages works, never suppresses all flashing
10. Reviewed [koreader/koreader#11110](https://github.com/koreader/koreader/issues/11110) — prior work on NGL4/NGL4e (bnrv1000/1100):
   confirmed `View.invalidate` works via view hierarchy but not ANativeWindow; identified
   `sunxihwc_eink` as the HWC layer; found `com.nook.action.full_refresh` broadcast intent
   as a potential no-root path; confirmed full waveform constant set matches `sunxi_kobo_h.lua`;
   bnrv1300 was explicitly unconfirmed in that issue — our sysfs work is the first confirmed implementation
