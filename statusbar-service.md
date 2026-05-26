# Nook Glowlight 4 Plus — IStatusBarService AIDL Analysis

This document catalogues every method exposed by `com.nook.lib.epdcommon.IStatusBarService`
on the Nook Glowlight 4 Plus (bnrv1300, Android 8.1) and explains what each one does,
based on decompiled sources (`nookPartner.apk`, `nookBnEreader.apk`).

Sources: decompiled APKs from the device.

---

## Service binding

```
Action:  com.nook.intent.action.statusbar
Package: com.nook.partner
Class:   com.nook.partner.statusbar.StatusBarService
```

No `android:permission` attribute — any app can bind without special permissions.
The service acts as a **capability-escalation proxy**: it runs as a privileged system
app (`DEVICE_POWER`, `WRITE_SETTINGS`, etc.) and exposes those capabilities to any
caller over AIDL.

---

## Method reference

### Group 1 — Status bar UI

Controls the nookPartner custom status bar overlay that sits at the top of the screen.

| Transaction | Method | Description |
|-------------|--------|-------------|
| 1 | `show()` | Show the status bar overlay |
| 2 | `hide()` | Hide the status bar overlay |
| 3 | `expand()` | Pull down the quick-settings panel |
| 4 | `expandDuration(int ms)` | Expand for `ms` milliseconds then auto-collapse |
| 5 | `collapse()` | Collapse the quick-settings panel |
| 6 | `update(int, String)` | Update content in the bar (battery icon, label text) |
| 7 | `progressBegin(String label)` | Show a spinner/progress indicator in the bar |
| 8 | `progressEnd()` | Dismiss the progress indicator |

---

### Group 2 — WiFi + Bluetooth (Direct Suspend)

See `nook-gl4plus-wifi-analysis.md` for full flow documentation.

| Transaction | Method | Description |
|-------------|--------|-------------|
| 22 | `setDirectSuspend(bool enable, bool saveOrRestore, bool force)` | Enable/disable direct suspend; optionally saves or restores WiFi+BT state |
| 23 | `getDirectSuspend()` | Returns current `power_enhance_enable` value from Settings.System |
| 24 | `setDirectSuspendTimeoutMillis(int ms)` | Change the 3-second delay before WiFi is killed (default 3000) |
| 25 | `getDirectSuspendTimeoutMillis()` | Read that timeout |
| 21 | `setForceKeepNetworkState(bool)` | Temporarily keep WiFi alive while a sync/download runs |
| 20 | `isWifiEnabledBeforeDirectSuspend()` | Read the saved pre-suspend WiFi state (`mWifiEnabledBeforeReaderResume`) |
| 26 | `resetWifiEnabledBeforeReaderResume()` | Clear the saved WiFi state |

---

### Group 3 — Privileged Settings writes

StatusBarService holds `WRITE_SETTINGS` system privilege and exposes it to any binder
caller. These two methods can write **any** `Settings.System` key — including keys
that are otherwise restricted to system apps.

| Transaction | Method | Description |
|-------------|--------|-------------|
| 11 | `settingsPutInt(String key, int value)` | Write any int to Settings.System |
| 12 | `settingsPutString(String key, String value)` | Write any string to Settings.System; special-cases `timezone` (calls `AlarmManager.setTimeZone`) and `time_12_24` (broadcasts `ACTION_TIME_SET`) |

**Known keys used in practice:**

| Key | Type | Used for |
|-----|------|----------|
| `screen_brightness` | int (0–100) | Frontlight brightness |
| `screen_brightness_color` | int (0–10) | Warmth level (written by GlowLightService after ÷10 rescaling) |
| `power_enhance_enable` | int (0/1) | Direct Suspend active flag |
| `lockscreen_status` | int (0/1) | Lock screen status flag (informational only — does not control PowerManagerService slide-to-unlock) |
| `time_12_24` | String | Clock format; triggers `ACTION_TIME_SET` broadcast when written |
| `timezone` | String | Device timezone; calls `AlarmManager.setTimeZone` when written |

---

### Group 4 — Frontlight

| Transaction | Method | Description |
|-------------|--------|-------------|
| 13 | `toggleGlowLight()` | Toggle frontlight on/off — equivalent to long-pressing the home button |
| 9 | `showGlowLightTip()` | Stub; implementation logs `"TODO: new impl."` — never finished |

---

### Group 5 — Status and system control

| Transaction | Method | Description |
|-------------|--------|-------------|
| 19 | `getBatteryLevel()` | Always returns `50.0f`; source comment: `"dummy data due to impl. not ready now"` — not implemented |
| 17 | `isLockScreenLocked()` | Returns `lockscreen_status == 1` from Settings.System |
| 18 | `isPowerOffScreenOn()` | Whether the sleep/shutdown image (`PowerOffScreenActivity`) is currently displayed |
| 16 | `isPartnerCrashed()` | Whether nookPartner has previously crashed and auto-recovered |
| 15 | `resetPartnerCrash()` | Clear the crash flag |
| 14 | `reboot(String reason)` | Trigger a full system reboot via `PartnerApplication.reboot()` |
| 10 | `showLeftCornerIcon(bool)` | Removed feature; logs `"unsupported now!"` |

---

## Slide-to-unlock: why IStatusBarService cannot help

The Nook's slide-to-unlock is implemented inside a **custom `PowerManagerService`**
baked into the system image (`/system/framework/`). It is controlled by the system
property `sys.mode.slideUnlock` (set to `true` by PowerManagerService each time it
locks the screen) and reads sleep artwork from `/system/media/SleepImageNook/`.

`IStatusBarService` has no method that reaches into `PowerManagerService`. The
`lockscreen_status` Settings.System key that `isLockScreenLocked()` reads is purely
informational and is not checked by `PowerManagerService` before showing the overlay.

Disabling the slide-to-unlock requires root:

```sh
# Persistent suppression via Magisk module service.sh:
while true; do
    val=$(getprop sys.mode.slideUnlock)
    if [ "$val" = "true" ]; then
        setprop sys.mode.slideUnlock false
    fi
    sleep 1
done
```

Install at `/data/adb/modules/no_slideunlock/service.sh` (chmod 755) with a matching
`module.prop`. Magisk runs `service.sh` as root after each boot.

---

## Notes on unimplemented / removed methods

- `getBatteryLevel()` — hardcoded `return 50.0f`; was never implemented.
- `showGlowLightTip()` — logs a TODO; never implemented.
- `showLeftCornerIcon(bool)` — logs "unsupported now!"; feature was removed.

These are safe to call (they won't crash) but return no meaningful data or action.

---

## Related services in com.nook.partner

| Service | Action / Class | Purpose |
|---------|---------------|---------|
| `StatusBarService` | `com.nook.intent.action.statusbar` | This service (IStatusBarService AIDL) |
| `GlowLightService` | `action_set_color_temperature` | Warmth control; separate started service, survives StatusBarService being disabled |
| `LockScreenService` | internal (not exported) | Nook custom lockscreen overlay; `addLockScreen()` is never called by any app outside nookPartner in the decompiled sources |
