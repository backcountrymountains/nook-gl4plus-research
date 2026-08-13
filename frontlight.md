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
persist the value. (The reset on *unlock* has a second, independent cause: see
[Color Temperature Management](#color-temperature-management-ctm) below.) KOReader handles
this in `powerd.lua` via `AndroidPowerD.init()`:

```lua
local saved = G_reader_settings:readSetting("frontlight_warmth") or 0
if saved > 0 then
    android.setScreenWarmth(math.floor(saved * self.warm_diff / 100))
end
```

`setWarmthHW()` saves to `G_reader_settings` and flushes on every change, so the value
survives app restarts without requiring system-level persistence.

---

## Color Temperature Management (CTM)

`GlowLightService` also owns B&N's CTM layer, which **re-applies a warmth value on every
`SCREEN_ON`** — after the framework has already restored `screen_brightness_color`. Whatever
CTM decides therefore wins over anything KOReader set before the screen went off.

`setupCTM()` (`GlowLightService.java:453`) branches on a mode persisted in the service's
own shared prefs — `/data/data/com.nook.partner/shared_prefs/ctm_preference.xml`, key
`ctm_mode`:

| Mode | Value | `setupCTM()` behaviour |
|------|-------|------------------------|
| `CTM_MODE_DISABLE` | `-1` | force `COLD_LIGHT` — **`0` on Emperor** |
| `CTM_MODE_MANUAL` | `0` | re-apply `manual_color_temperature` from prefs |
| `CTM_MODE_AUTO` | `1` | sunrise/sunset from location |
| `CTM_MODE_SCHEDULE` | `2` | sunrise/sunset from user-set times |

```java
// GlowLightService.java:453
private void setupCTM() {
    initIfNeed();
    android.util.Log.i(TAG, "setupCTM:" + getCTMMode(this));
    if (getCTMMode(this) == -1) {
        setFrontLightBrightnessColor(GlowLightUtils.COLD_LIGHT, false);
        return;
    }
    ...
```

Two details make mode `-1` a trap rather than a preference:

- **`getCTMMode()` defaults to `-1`** when the key is absent (`GlowLightService.java:682`),
  so a *missing* pref is indistinguishable from a deliberate "CTM off".
- **In mode `-1`, `action_set_color_temperature` does not persist.** `saveColorTemperature(i, true)`
  delegates to `getMode().saveColorTemperatureByTime(i)`; with no mode set, `getMode()` returns
  a `ScheduleMode`, whose `saveColorTemperatureByTime()` returns early when sunrise/sunset are
  `null` (`CTMMode.java:88`). The value reaches the hardware and is lost at the next unlock.

In mode `0` the same intent routes to `ManualMode.saveColorTemperatureByTime()`, which writes
`manual_color_temperature` — so KOReader's warmth slider and CTM's stored value stay in sync,
and the value survives unlock.

`COLD_LIGHT`, `DAY_LIGHT` and `TUGSTEN_LIGHT` are **inverted on this device**
(`GlowLightUtils.java:38-40`) — on Emperor, cold is `0` and warm is `87`:

```java
COLD_LIGHT   = EpdUtils.isDeviceEmperor() ? 0  : 100;
DAY_LIGHT    = EpdUtils.isDeviceEmperor() ? 12 : 88;
TUGSTEN_LIGHT= EpdUtils.isDeviceEmperor() ? 87 : 13;
```

Note that `ManualMode`'s fallback is `DAY_LIGHT` = `12` on the 0–100 scale = **1 of 10** on
the hardware. Setting mode `0` without seeding `manual_color_temperature` therefore still
looks almost cold — the mode and the value must both be set.

### Recovering after an unclean shutdown

`ctm_mode` lives *only* in `ctm_preference.xml`. **Nothing re-establishes it at boot** —
`ACTION_ENABLE_CTM` is sent only by B&N's own glowlight UI (`GlowLightUtils.java:146`), and
no `BOOT_COMPLETED` receiver in `nookPartner` touches CTM. A thermal shutdown, a battery
pull, or any hard power cut can lose that file's contents (SharedPreferences commit not yet
flushed to disk), and the device then forces cold light after every unlock, permanently.

**Symptom:** warmth resets to cold on every unlock; logcat shows

```
I/CTMService( <pid> ): setupCTM:-1
V/LightsService( 1896 ): Jungwen-LightService- kk-1-brightness(color):0
E/lights  ( 1718 ): backlight-color: set_light, max_color=10, target brightness=0
```

**Diagnose** — one call, no root:

```bash
# turn the screen off and on, then:
adb shell settings get system screen_brightness_color   # 0 after an unlock you didn't ask for
```

Or read the mode directly (root):

```bash
adb shell su -c 'cat /data/data/com.nook.partner/shared_prefs/ctm_preference.xml'
```

A file containing *only* `<int name="color_temperature" value="0" />` is the fingerprint:
that is exactly what the mode `-1` path writes when it recreates the file from scratch
(`setFrontLightBrightnessColor(COLD_LIGHT, false)` → `saveColorTemperature(0, false)`, which
skips the manual-value write).

**Repair** — no root, order matters, idempotent:

```bash
# 1. CTM -> MANUAL, so setupCTM() re-applies a stored value instead of forcing cold
adb shell am startservice -n com.nook.partner/.service.GlowLightService \
  -a action_set_ctm_mode --ei extra_ctm_mode 0

# 2. seed that stored value (0-100 scale; 100 = warmth 10, 0 = cold)
adb shell am startservice -n com.nook.partner/.service.GlowLightService \
  -a action_set_color_temperature --ei extra_color_temperature 100
```

Step 1 alone leaves warmth at `DAY_LIGHT`/10 = 1. `GlowLightService` is an `IntentService`,
so the two intents are handled in the order sent.

Verify by cycling the screen — `screen_brightness_color` must hold its value:

```
setupCTM:0
Jungwen-LightService- kk-1-brightness(color):10
```

**There is no on-device equivalent via `com.example.ctm` ("Display Settings").** Tested
2026-08-13: sliding its warmth control drove the hardware (`kk-1-brightness(color):3→2→1→0→9→10`)
with **no `CTMService` line in logcat at all** — the app holds `DEVICE_POWER` and calls
`LightsService` directly, bypassing `GlowLightService`'s intent API. `ctm_mode` is never
written, so the value still dies at the next unlock (verified: 10 → 0 across one screen
cycle). It changes the light, not the setting that survives unlock.

The only UI that *would* repair the mode is `NightModeSettingsFragment` — but that lives in
`bn.ereader`, which is disabled on any device set up to run KOReader as its reader.
`QuickSettings` in nookPartner also calls `GlowLightUtils.setupCTMMode()`
(`QuickSettings.java:615-618`, gated on `ro.bn.ctm`, `true` on this firmware), but it is
reachable only from B&N's own status bar. **Untested.**

**In KOReader:** `NookGL4plusController.assertManualCtmMode()` sends intent 1 once per
process, immediately before the first warmth write (which supplies intent 2) — so simply
launching a build that includes it repairs the device.

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

### Warmth resets to cold on every unlock

CTM is in mode `-1` and forcing `COLD_LIGHT`. Usually the aftermath of an unclean shutdown.
Confirm with `adb logcat | grep setupCTM` — a `setupCTM:-1` immediately followed by
`kk-1-brightness(color):0` is definitive. See
[Recovering after an unclean shutdown](#recovering-after-an-unclean-shutdown).

### Warmth not restored after reboot

The value in `G_reader_settings` (`frontlight_warmth`) should be pushed back to hardware
on KOReader startup. If it isn't: confirm `AndroidPowerD.init()` is being called and
that `screen_brightness_color` is readable from Settings.System.
