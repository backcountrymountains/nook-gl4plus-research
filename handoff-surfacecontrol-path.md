# Handoff: ViewRootImpl.setRefreshMode — COMPLETED

## Final outcome (2026-06-18)

**GC16 via `ViewRootImpl.setRefreshMode` works. Magisk `epd_gc16` module retired.**

---

## What was implemented

`NookEmperorEPDController.kt` tries three paths on every `setEpdMode` call:

1. **ViewRootImpl direct path** (preferred, no root required): reflects into
   `ViewRootImpl.setRefreshMode(int)` — a B&N-specific addition to Android 8.1's
   `ViewRootImpl`. Routes through SurfaceFlinger → HWC → `layer->refreshMode` → EPDC driver.
2. **SurfaceControl path** (AOSP Android 10+ fallback): reflects into
   `ViewRootImpl.mSurfaceControl` and calls `SurfaceControl.setRefreshMode(int)`.
3. **Sysfs path** (last resort, requires Magisk `epd_gc16` module): writes to
   `force_update_mode`.

---

## Key findings from testing

### ViewRootImpl field enumeration
B&N's Android 8.1 `ViewRootImpl` does **not** have `mSurfaceControl` (an AOSP Android 10+
addition). Fields present: `mSurface : android.view.Surface`, `mSurfaceHolder`, etc.
Static field `DEBUG_EPDC : boolean` confirms B&N added custom EPDC code.

### ViewRootImpl method enumeration
B&N added three EPDC methods directly to `ViewRootImpl`:
- `setRefreshMode(int) : void` — the main waveform control ✅ **used**
- `setGu16RefreshLimit(int) : void` — GU16 partial refresh limiter
- `forceGlobalRefresh(boolean) : void` — force full-screen refresh

### Surface EPDC methods
B&N also added to `android.view.Surface`:
- `addEpdc(int[]) : void` — per-buffer EPDC linked list (Java wrapper)
- `nativeAddEpdc(long, int[]) : void` — native backing
- `setAutoRefreshEnabled(boolean) : void`
- `isAutoRefreshEnabled() : boolean`

### GC16 confirmation
`setRefreshMode(0x4)` → kernel sees `mode=0x200004` (GC16 ✓) on page turns.
Confirmed **without** the Magisk `epd_gc16` module after reboot.

### GLR16 status
`setRefreshMode(0x40)` is accepted without error but HWC silently maps it to
`mode=0x200084` (GU16) during composition. GLR16 is effectively unavailable on
the shipping firmware via this path.

The `Surface.addEpdc(int[])` path (per-buffer, different HWC code path) remains
unexplored. The `int[]` format would need to be reverse-engineered from `libgui.so`.

---

## Final state

| Item | Status |
|---|---|
| GC16 on page turns | ✅ Working via `ViewRootImpl.setRefreshMode(0x4)` |
| GC16 without Magisk module | ✅ Confirmed |
| Magisk `epd_gc16` module | ✅ Retired (can be uninstalled) |
| GLR16 via `setRefreshMode(0x40)` | ❌ HWC maps to GU16 |
| GLR16 via `Surface.addEpdc` | ❓ Unexplored — format unknown |

---

## Files changed

| File | Change |
|---|---|
| `platform/android/luajit-launcher/app/src/main/java/org/koreader/launcher/device/epd/NookEmperorEPDController.kt` | VRI direct path, SurfaceControl fallback, updated comments |
| `nook-gl4plus-research/handoff-surfacecontrol-path.md` | This file — final results |

---

## Related documents

- [`eink.md`](eink.md) — original GC16 investigation, sysfs path, waveform constants
- [`hwc-hal-reverse-engineering.md`](hwc-hal-reverse-engineering.md) — full RE of HWC blobs
