# Nook Glowlight 4 Plus — E-Ink Refresh and Frontlight

This document covers how KOReader drives the e-ink panel on the GL4 Plus
and how the frontlight (brightness + warmth) implementation works, including
the differences from the generic Android fallback that was in place before
device-specific support was added.

---

## E-ink refresh: native Linux vs. Android

### Native devices (Kindle, Kobo)

On Kindle and Kobo, KOReader runs on Linux with direct hardware access.
The e-ink panel is driven by a Freescale/NXP `mxcfb` (or `epdc`) kernel
module, exposed as `/dev/fb0`. KOReader:

1. `mmap()`s the framebuffer and writes pixel data directly.
2. Issues `ioctl(MXCFB_SEND_UPDATE, ...)` to tell the EPD controller
   "refresh this region using this waveform."

Waveform modes are the key lever — KOReader picks one per update:

| Mode | Character | Typical use |
|------|-----------|-------------|
| **GC16** | Full 16-level grayscale, slow flash-and-redraw | Page turns |
| **GL16 / REAGL** | Ghost-reduction variant, preserves sharpness | Multi-page partial updates |
| **A2** | Fast binary (black/white only) | Rapid highlights, cursors |
| **DU** | Directional partial, fast | UI elements, menus |

This is the `framebuffer_mxcfb.lua` path: ~800 lines of waveform constants,
region-tracking logic, and synchronization markers. A page turn typically
does a fast A2 flash first, then settles with GC16 — giving the appearance
of speed without ghosting.

### Android devices

On Android the framebuffer is hidden behind SurfaceFlinger/hwcomposer. Apps
write to an `ANativeWindow` (Android surface), not directly to `/dev/fb0`.
KOReader's `framebuffer_android.lua` calls
`android.einkUpdate(mode, delay, x, y, w, h)`, which routes into Java/Kotlin.
The Java layer calls `EPDFactory.epdController.setEpdMode()` — a
device-specific implementation selected at startup.

---

## EPD controller for the GL4 Plus — `NookEmperorEPDController`

The GL4 Plus uses a mechanism discovered by reverse-engineering B&N's own
`com.nook.partner` app (`EpdDisplayControllerImpl`): **calling
`View.invalidate(int)` via reflection**.

```kotlin
// NookEmperorEPDController.kt
Class.forName("android.view.View")
    .getMethod("invalidate", Integer.TYPE)
    .invoke(targetView, mode)
```

The standard Android `View.invalidate()` takes no argument and simply marks
the view dirty. B&N's customized AOSP adds a hidden overload
`View.invalidate(int)` that routes the integer argument as an EPD waveform
command directly to the display driver — the same hook `com.nook.partner`
uses internally.

### Waveform constants (from sunxi-kobo.h)

```kotlin
const val EMPEROR_EINK_GC16_MODE = 0x04
const val EMPEROR_EINK_GU16_MODE = 0x84
const val EMPEROR_EINK_NO_MERGE  = Integer.MIN_VALUE  // 0x80000000
```

The controller reports `getMode() = "full-only"`, so KOReader only ever
calls the full-quality path: `GC16 | NO_MERGE = 0x80000004`. Partial waveform
definitions exist but are never used. Every screen update is a full-quality
flash — this is why page turns are notably slower on the GL4 Plus than on a
Kobo (no two-phase A2-then-GC16 update).

### `needsView() = false`

Unlike earlier Nook controllers (e.g. `NGL4EPDController` used for the GL4),
`NookEmperorEPDController` does **not** create a `NativeSurfaceView`. The
content view (`window.decorView.findViewById(android.R.id.content)`) is
sufficient for the `invalidate(int)` driver hook, and skipping the surface
setup avoids a crash on the Emperor hardware.

### EPD factory routing

`EPDFactory.kt` selects the controller by device ID:

```kotlin
DeviceInfo.Id.NOOK_GL4PLUS -> NookEmperorEPDController()
DeviceInfo.Id.NOOK_GL4     -> NGL4EPDController()         // GL4 / GL4e
```

`DeviceInfo` identifies the GL4 Plus as:

```kotlin
MANUFACTURER == "barnesandnoble" && MODEL == "bnrv1300" -> Id.NOOK_GL4PLUS
```

---

## Frontlight: brightness and warmth

### Before device-specific support

Before `NookGL4plusController` was added, `LightsFactory.kt` had no entry for
`NOOK_GL4PLUS` and fell through to `GenericController`. Problems:

- **Brightness** was set via `window.attributes.screenBrightness` — the
  Android window-level float parameter. This doesn't reliably track the
  hardware frontlight LED on this device.
- **Scale** was 0–255 (wrong — the GL4 Plus hardware uses 0–100).
- **Warmth** was a no-op (`setWarmth` logged "not implemented" and returned).

### `NookGL4plusController`

`LightsFactory.kt` now routes `NOOK_GL4PLUS` to `NookGL4plusController`:

```kotlin
DeviceInfo.Id.NOOK_GL4PLUS -> NookGL4plusController()
```

#### Brightness

Writes directly to `Settings.System.SCREEN_BRIGHTNESS` — the same system
setting the Nook's own Settings app uses. This drives the actual hardware LED.
Scale is 0–100 (`BRIGHTNESS_MAX = 100`).

```kotlin
Settings.System.putInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS, brightness)
```

Requires the "Modify system settings" special app permission, grantable
without root:

```sh
adb shell appops set org.koreader.launcher WRITE_SETTINGS allow
```

#### Warmth

The warmth LED is driven by an LM3630A chip. Writing to it directly requires
`DEVICE_POWER` privilege — a Nook-specific permission not grantable to
third-party apps even with root through normal Android paths.

Instead, `NookGL4plusController` sends an intent to
`com.nook.partner/.service.GlowLightService`, which holds `DEVICE_POWER`
and calls `PowerManager.setFrontlightBrightnessColor()` internally:

```kotlin
val intent = Intent("action_set_color_temperature").apply {
    component = ComponentName("com.nook.partner", "com.nook.partner.service.GlowLightService")
    putExtra("extra_color_temperature", warmth * 10)  // KOReader 0-10 → service 0-100
}
activity.startService(intent)
```

Scale pipeline:
```
KOReader fl_warmth (0–10)
  × 10 → GlowLightService intent extra (0–100)
  ÷ 10 → LM3630A hardware register (0–10)
```

`GlowLightService` is exported with no permission requirement, so any app can
send it this intent without root. The service also writes the result back to
`Settings.System.screen_brightness_color`, which is how `getWarmth()` reads
the current value:

```kotlin
Settings.System.getInt(contentResolver, "screen_brightness_color")
```

#### Warmth persistence

The sysfs warmth node resets on every app start and resume (the AllWinner
driver does not persist it). `AndroidPowerD.init()` in KOReader reads the
saved warmth from `G_reader_settings` and pushes it back to hardware on
startup:

```lua
-- powerd.lua
local saved = G_reader_settings:readSetting("frontlight_warmth") or 0
if saved > 0 then
    android.setScreenWarmth(math.floor(saved * self.warm_diff / 100))
end
```

`setWarmthHW()` saves to `G_reader_settings` and flushes on every change so
the value survives restarts.

---

## Summary of differences

| | Generic (before) | NookGL4plusController (now) |
|---|---|---|
| Brightness mechanism | `window.attributes.screenBrightness` | `Settings.System.SCREEN_BRIGHTNESS` |
| Brightness scale | 0–255 | 0–100 |
| Warmth | No-op | `GlowLightService` intent → LM3630A |
| Root required | No | No |
| Warmth persistence | N/A | Saved to KOReader settings, restored on resume |
