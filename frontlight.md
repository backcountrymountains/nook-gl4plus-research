# Nook Glowlight 4 Plus — Frontlight (Brightness + Warmth)

## Overview

The GL4 Plus has a two-channel frontlight: cool white LEDs for brightness and warm
amber LEDs for warmth/color temperature. Both channels require device-specific
handling — the generic KOReader Android fallback gets both wrong.

---

## Hardware

- **Brightness**: Cool white LEDs, controlled via `Settings.System.SCREEN_BRIGHTNESS`
  (0–100 scale, matching the Nook's own Settings app)
- **Warmth**: Warm amber LEDs driven by an **LM3630A** dual-channel LED driver chip
- **Warmth privilege**: Writing to the LM3630A requires `DEVICE_POWER` — a Nook-specific
  system permission not grantable to third-party apps via normal Android paths

---

## What the generic fallback did wrong

Before `NookGL4plusController`, `LightsFactory.kt` had no entry for `NOOK_GL4PLUS` and fell
through to `GenericController`. Problems:

| | Generic (wrong) | NookGL4plusController (correct) |
|---|---|---|
| Brightness mechanism | `window.attributes.screenBrightness` | `Settings.System.SCREEN_BRIGHTNESS` |
| Brightness scale | 0–255 | 0–100 |
| Warmth | No-op (logged "not implemented") | `GlowLightService` intent → LM3630A |
| Root required | No | No |

`window.attributes.screenBrightness` is a window-level float that doesn't reliably
track the hardware LED on this device. Only the system setting drives the actual hardware.

---

## `NookGL4plusController`

Located in:
`platform/android/luajit-launcher/app/src/main/java/org/koreader/launcher/device/lights/NookGL4plusController.kt`

Factory routing in `LightsFactory.kt`:
```kotlin
DeviceInfo.Id.NOOK_GL4PLUS -> NookGL4plusController()
```

### Brightness

Writes directly to `Settings.System.SCREEN_BRIGHTNESS`:

```kotlin
const val BRIGHTNESS_MAX = 100

override fun setBrightness(activity: Activity, brightness: Int) {
    Settings.System.putInt(
        activity.contentResolver,
        Settings.System.SCREEN_BRIGHTNESS,
        brightness
    )
}
```

Scale is 0–100. The Nook's own Settings app uses the same system setting and the same scale.

#### WRITE_SETTINGS permission

`Settings.System.putInt` requires the "Modify system settings" special app permission.
Grant it once after each fresh install — no root needed.

**Via ADB:**
```sh
adb shell appops set org.koreader.launcher WRITE_SETTINGS allow
```

**Via the system UI:** long-press the KOReader icon → **App Info** → **Advanced** →
**Modify system settings** → toggle **Allow**.

Without this, every brightness write throws a `SecurityException` logged by KRP. The
permission survives app updates but is cleared on full reinstall or data wipe.

---

### Warmth

The LM3630A chip requires `DEVICE_POWER` privilege, so KOReader can't write to it
directly. Instead, the controller sends an intent to B&N's `GlowLightService`, which
holds the privilege and calls `PowerManager.setFrontlightBrightnessColor()` internally:

```kotlin
const val WARMTH_MAX = 10

override fun setWarmth(activity: Activity, warmth: Int) {
    val intent = Intent("action_set_color_temperature").apply {
        component = ComponentName(
            "com.nook.partner",
            "com.nook.partner.service.GlowLightService"
        )
        putExtra("extra_color_temperature", warmth * 10)  // 0–10 → 0–100
    }
    activity.startService(intent)
}
```

`GlowLightService` is exported with no permission requirement — any app can send this
intent without root. B&N intentionally made it public, presumably for third-party
integrations.

#### Scale pipeline

```
KOReader fl_warmth     0–10
  × 10 → intent extra  0–100   (GlowLightService "extra_color_temperature")
  ÷ 10 → LM3630A       0–10    (done internally by GlowLightService)
```

#### Reading warmth back

`GlowLightService` writes the warmth value to `Settings.System.screen_brightness_color`
(a B&N extension, not a standard Android setting). `getWarmth()` reads from there:

```kotlin
override fun getWarmth(activity: Activity): Int {
    val raw = Settings.System.getInt(
        activity.contentResolver,
        "screen_brightness_color",
        0
    )
    return raw / 10
}
```

---

## Warmth persistence

The AllWinner driver resets the warm LED on every app start and resume — it does not
persist the value. KOReader handles this in `powerd.lua` via `AndroidPowerD.init()`:

```lua
local saved = G_reader_settings:readSetting("frontlight_warmth") or 0
if saved > 0 then
    android.setScreenWarmth(math.floor(saved * self.warm_diff / 100))
end
```

`setWarmthHW()` saves to `G_reader_settings` and flushes on every change, so the value
survives app restarts without requiring system-level persistence.

---

## GlowLightService discovery

The service was found by decompiling `com.nook.partner`:

```
nook-decompiled/nookPartner/sources/com/nook/partner/service/GlowLightService.java
```

Key details from the decompiled source:
- Action string: `"action_set_color_temperature"`
- Extra key: `"extra_color_temperature"` (int, range 0–100)
- Calls `PowerManager.setFrontlightBrightnessColor(value)` internally
- Writes result to `Settings.System.screen_brightness_color`
- Component: `com.nook.partner/.service.GlowLightService`

The `PowerManager.setFrontlightBrightnessColor()` call is a B&N AOSP extension
(not present in AOSP) that ultimately writes to the LM3630A register via a HAL.

---

## Integration with KOReader's lights system

KOReader's `BasePowerD` tracks brightness and warmth independently. Both use the
`canSetBrightness()` / `canSetWarmth()` flags to enable the relevant slider in
the frontlight popup.

`NookGL4plusController` returns:
```kotlin
override fun hasWarmth(): Boolean = true
override fun getBrightnessMax(): Int = BRIGHTNESS_MAX  // 100
override fun getWarmthMax(): Int = WARMTH_MAX          // 10
```

The frontlight popup slider maps 0–100 for brightness and 0–10 for warmth, matching
the hardware ranges exactly (no rescaling in the Lua layer).

---

## `com.nook.partner` package requirements

Warmth depends on `GlowLightService`, which lives inside the `com.nook.partner` system
app. Two conditions must hold:

1. The `com.nook.partner` **package** must not be disabled wholesale.
2. `com.nook.partner.service.GlowLightService` must not be individually disabled.

`GlowLightService` is **independent** of `StatusBarService` — disabling `StatusBarService`
(to suppress temperature warning dialogs or the B&N status overlay) does not affect warmth.

### If you previously disabled `com.nook.partner`

Many GL4 Plus users disable `com.nook.partner` to remove the B&N launcher and block OTA
updates. This also kills `GlowLightService`. To restore warmth without reinstating the
B&N ecosystem, re-enable the package and then selectively re-disable the components you
don't want:

```sh
# Step 1 — re-enable the package so GlowLightService can start
adb shell pm enable com.nook.partner

# Step 2 — re-disable the components you had disabled before
# B&N launcher
adb shell su -c 'pm disable com.nook.partner/.FacadeLauncherActivity'
adb shell su -c 'pm disable com.nook.partner/.OobeLauncherActivity'
# OTA update system
adb shell su -c 'pm disable com.nook.partner/.otamanager.OtaIntentService'
adb shell su -c 'pm disable com.nook.partner/.otamanager.SideloadInstaller'
adb shell su -c 'pm disable com.nook.partner/.oobe.OobeOtaActivity'
# B&N status bar / temperature warnings (optional — see temperature-management.md)
adb shell su -c 'pm disable com.nook.partner/.statusbar.StatusBarService'
```

Do NOT disable `com.nook.partner.service.GlowLightService` itself.

Verify the result:
```sh
adb shell dumpsys package com.nook.partner | grep -A 20 disabledComponents
# GlowLightService should NOT appear in this list
```

---

## Troubleshooting

### Brightness slider does nothing

Most likely cause: `WRITE_SETTINGS` not granted.

```sh
adb shell appops get org.koreader.launcher WRITE_SETTINGS
# Should say: WRITE_SETTINGS: allow
# If it says:  WRITE_SETTINGS: default  →  run the grant command below
adb shell appops set org.koreader.launcher WRITE_SETTINGS allow
```

Check logcat for SecurityException:
```sh
adb logcat -d | grep -i "securityexception"
```

### Warmth slider does nothing / warmth resets after resume

1. Check `GlowLightService` is running: `adb shell dumpsys activity services com.nook.partner`
2. If nothing is listed, `com.nook.partner` may be disabled — see
   [`com.nook.partner` package requirements](#comnookpartner-package-requirements) above
   for the re-enable / selective re-disable procedure
3. After resume, check KOReader's warmth restore logic fires — look for `setScreenWarmth`
   in logcat

### Warmth not restored after reboot

The value in `G_reader_settings` (`frontlight_warmth`) should be pushed back to hardware
on KOReader startup. If it isn't: confirm `AndroidPowerD.init()` is being called and
that `screen_brightness_color` is readable from Settings.System.
