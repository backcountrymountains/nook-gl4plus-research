# Nook Glowlight 4 Plus — Power Management

This document covers the device's power management mechanisms relevant to e-reader
use: deep sleep between page turns via `power_enhance_enable`, the AllWinner
`PowerManagerEx` framework layer, the slide-to-unlock overlay, and the
[nopowen](https://github.com/Codereamp/nopowen) KOReader patch.

---

## Deep sleep via `power_enhance_enable`

### The setting

`power_enhance_enable` is a `Settings.System` integer key (0 or 1) used to signal
that the device should enter a low-power state:

```sh
adb shell settings put system power_enhance_enable 1   # enter deep sleep mode
adb shell settings put system power_enhance_enable 0   # exit deep sleep mode
```

Writing to it requires the "Modify system settings" special app permission
(`WRITE_SETTINGS`), grantable without root:

```sh
adb shell appops set <package> WRITE_SETTINGS allow
```

### What happens when it changes

The Android framework on this device includes `PowerManagerEx`, an AllWinner-specific
power management extension. It registers a `Settings.System` content observer on
`power_enhance_enable` and responds near-instantly (within 100 ms):

```
PowerManagerEx-JNI: [disable] nativeSetCpuBoostEx is 0   ← on power_enhance_enable=0
PowerManagerEx-JNI: [disable] nativeSetCpuBoostEx is 1   ← on power_enhance_enable=1
```

`nativeSetCpuBoostEx` is a native (C) JNI function that adjusts CPU power behaviour
at the hardware level. The exact effect (frequency scaling, governor switch, or
peripheral gating) is not visible via standard sysfs while USB/ADB is connected,
because the USB wakelock forces the CPU to a performance state that masks any
reduction.

### What "deep sleep" means on this device

This is **not** suspend-to-RAM. The kernel does not log suspend/resume events in
response to `power_enhance_enable` changes. Instead, "deep sleep" here means the
CPU power profile is reduced between page turns while the e-ink screen image is
preserved without refreshing. The device remains responsive and ADB-connected.

On the stock Nook firmware, `StatusBarService` also disables WiFi and Bluetooth
before setting `power_enhance_enable = 1` to maximise savings. See
[wifi-and-direct-suspend.md](wifi-and-direct-suspend.md) for that mechanism.

---

## nopowen KOReader patch

[nopowen](https://github.com/Codereamp/nopowen) (v20231105) is a KOReader Lua
patch that automates the `power_enhance_enable` cycle on every page turn.

### Installation

Copy `2111-nopowen-patch.lua` to the KOReader patches directory on the device:

```
/sdcard/koreader/patches/2111-nopowen-patch.lua
```

Grant "Modify system settings" to KOReader (one-time, no root):

```sh
adb shell appops set org.koreader.launcher WRITE_SETTINGS allow
```

Fully exit and restart KOReader via its Exit menu.

### What it does on each page turn

1. Sets `power_enhance_enable = 0` (exit deep sleep for page render).
2. Renders the page normally.
3. Schedules `power_enhance_enable = 1` after 1 second (configurable via
   `DS_DELAY_PAGES`).

On book open, the same cycle runs with a 4-second initial delay (`DS_DELAY_INTERCEPT`).

### Verified working on GL4 Plus

Confirmed via logcat — no JNI exceptions, all `Settings.System` writes succeed:

```
KOReader: KRP: i_am_paging!
KOReader: KRP: reseting deepsleep (setting power_enhance_enable to 0)
KOReader: KRP: settings set returned ok
KOReader: KRP: scheduling DS for seconds: 1
KOReader: KRP: scheduled event. Setting power_enhance_enable to 1 (going to deep sleep)
KOReader: KRP: settings set returned ok
```

### Limitations on GL4 Plus vs GL4/GL4e

The patch was written for the Nook Glowlight 4/4e. On the GL4 Plus:

- The `PowerManagerEx`/`nativeSetCpuBoostEx` response is confirmed active.
- `StatusBarService` is the component that would normally also disable WiFi/BT
  before deep sleep; if it is disabled (see
  [temperature-management.md](temperature-management.md)), WiFi/BT management
  must be handled separately (e.g., via KOReader's built-in WiFi toggle).
- Actual battery savings vs. the GL4/GL4e have not been formally measured on the
  GL4 Plus. Real-world comparison requires an unplugged reading session.

---

## Slide-to-unlock

### What it is

When the power button is pressed to wake the device from sleep, a "slide to unlock"
animation is displayed before the home screen appears. This is **not** the Android
keyguard — the standard Android keyguard is disabled on this device
(`Settings.Secure lockscreen.disabled = 1`).

The slide-to-unlock is a custom addition to `PowerManagerService` in the Nook
system image (`/system/framework/services.jar`). It is controlled by two system
properties set at runtime by `PowerManagerService` itself:

```
sys.mode.slideUnlock              (true/false)
sys.mode.slideUnlockBackgroundImage  (e.g. Art2_bk.png)
```

Artwork is loaded from `/system/media/SleepImageNook/` (Art1–Art6, black/white
variants).

### Why app-layer approaches don't work

| Approach | Why it fails |
|----------|-------------|
| `Settings.System lockscreen_status = 0` | Only read by `IStatusBarService.isLockScreenLocked()` for reporting; `PowerManagerService` ignores it |
| `Settings.Secure lockscreen.disabled = 1` | Already set; controls Android keyguard, not this overlay |
| `IStatusBarService` AIDL | Has no method that reaches into `PowerManagerService` |
| `DevicePolicyManager.setKeyguardDisabled()` | Controls Android keyguard only |
| `setprop sys.mode.slideUnlock false` | `PowerManagerService` resets it to `true` on every lock |
| Regular app `setprop` | Requires `CHANGE_CONFIGURATION` (platform signature); not grantable to user apps |

### Root-based suppression (Magisk)

`PowerManagerService` writes `sys.mode.slideUnlock = true` each time it locks the
screen, but it also reads it before showing the overlay on wake. A background watcher
that resets it to `false` after each write effectively prevents the overlay.

**Magisk module setup** (`/data/adb/modules/no_slideunlock/`):

`module.prop`:
```
id=no_slideunlock
name=Disable Slide-to-Unlock
version=v1
versionCode=1
author=local
description=Prevents PowerManagerService from showing the slide-to-unlock overlay
```

`service.sh` (chmod 755):
```sh
#!/system/bin/sh
while true; do
    val=$(getprop sys.mode.slideUnlock)
    if [ "$val" = "true" ]; then
        setprop sys.mode.slideUnlock false
    fi
    sleep 1
done
```

Magisk runs `service.sh` as root after each boot. The 1-second poll interval is
sufficient because `PowerManagerService` sets the property when the power button is
pressed to lock (not at wake time), so the watcher has time to reset it before the
next wake.

To remove: delete `/data/adb/modules/no_slideunlock/` and reboot.

---

## Related

- [wifi-and-direct-suspend.md](wifi-and-direct-suspend.md) — Direct Suspend: WiFi/BT management tied to `power_enhance_enable`
- [statusbar-service.md](statusbar-service.md) — `IStatusBarService` AIDL reference
- [temperature-management.md](temperature-management.md) — temperature warnings and StatusBarService
