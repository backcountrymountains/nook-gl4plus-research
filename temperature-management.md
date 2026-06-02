# Nook Glowlight 4 Plus — Temperature Management

This document covers how the device monitors battery temperature, what triggers the
warning dialog and thermal shutdown, and how to suppress the dialog without
compromising safety.

Sources: decompiled `nookPartner.apk` (`BatteryIcon.java`, `StatusBarService.java`,
`PowerOffScreenActivity.java`); analysis of `SystemUI.vdex` and `framework-res.apk`
from the device.

---

## Temperature thresholds

All thresholds are in tenths of a degree Celsius (as reported by the
`android.intent.action.BATTERY_CHANGED` broadcast's `temperature` extra).

| Constant | Raw value | °C | Action |
|----------|-----------|-----|--------|
| `CHG_TEMP_HIGH_SHUTDOWN` | 500 | 50°C | Immediate shutdown |
| `CHG_TEMP_HIGH_ALARM`    | 480 | 48°C | Warning dialog |
| `CHG_TEMP_LOW_ALARM`     | 80  | 8°C  | Warning dialog |
| `CHG_TEMP_LOW_SHUTDOWN`  | 50  | 5°C  | Immediate shutdown |

---

## Where the logic lives

There are **two independent** temperature warning implementations on this device.
Disabling only the nookPartner one still leaves the SystemUI one active.

### Layer 1 — nookPartner (com.nook.partner)

`com.nook.partner.statusbar.BatteryIcon.checkBatteryTemperature(int temp)`:

```java
private void checkBatteryTemperature(int temp) {
    if (temp > 500 || temp < 50) {
        shutdown();           // > 50°C or < 5°C
        return;
    }
    if (temp > 480) {
        showAlertDialog();    // 48–50°C
    } else if (temp < 80) {
        showAlertDialog();    // 5–8°C
    } else if (sAlertDialog.isShowing()) {
        sAlertDialog.dismiss();
    }
}
```

`BatteryIcon` is a custom `View` inflated inside `StatusBarService`. It registers a
`BroadcastReceiver` for `ACTION_BATTERY_CHANGED` and calls
`checkBatteryTemperature()` on every battery update.

### Layer 2 — com.android.systemui (custom Nook code)

The Nook's `SystemUI.apk` contains additional temperature warning logic added
directly to `com.android.systemui.statusbar.phone.StatusBar` and/or
`QuickPanelController`. These classes also register for `ACTION_BATTERY_CHANGED`
(visible in logcat as `D StatusBar: pulgType=` and `D QuickPanelController:
plugType=` at PID 1992) and can independently show a high-temperature dialog.

Evidence: `SystemUI.vdex` contains the strings `show_temperature_warning`,
`warning_temperature`, `showHighTemperatureDialog`, `mHighTempDialog`, and
`PowerNotificationWarnings` — but the device's `framework-res.apk` does **not**
contain `config_showTemperatureWarning` or `config_warningTemperature`. Standard
AOSP `PowerUI` is therefore disabled; the dialog comes from the Nook-custom code.

The SystemUI temperature dialog is gated by `Settings.Global.show_temperature_warning`.
Setting it to `0` suppresses it.

---

## Warning dialog

The nookPartner dialog is a Nook `AlertDialog` with the `ic_batttery_temperature`
drawable and an "OK" dismiss button. The SystemUI dialog uses Android's
`PowerNotificationWarnings` UI. Both fire around 48°C based on observed behaviour.

To suppress both dialogs:

---

## Shutdown action

`BatteryIcon.shutdown()` sends:

```java
Intent intent = new Intent("android.intent.action.ACTION_REQUEST_SHUTDOWN");
intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
context.startActivity(intent);
```

This is the standard Android soft shutdown intent, handled by the system server.
It is guarded by `EpdUtils.isEpdSimulator()` — on the real device that returns
false, so shutdown always proceeds.

---

## Shutdown image

When the device shuts down due to temperature, `PowerOffScreenActivity` is shown
before power-off. It reads the battery temperature from `ACTION_BATTERY_CHANGED`
and selects the sleep image accordingly:

| Condition | Image shown |
|-----------|-------------|
| `temp > 500` (> 50°C) | `temperature_warning_hot` |
| `temp < 50` (< 5°C) | `temperature_warning_cold` |
| Normal | Battery level / standard power-off art |

The sleep artwork lives in `/system/media/SleepImageNook/` (Art1–Art6 PNG files).

---

## How to suppress the warning dialogs

### Step 1 — Disable nookPartner StatusBarService (Layer 1)

```sh
adb shell su -c 'pm disable com.nook.partner/.statusbar.StatusBarService'
adb shell am force-stop com.nook.partner
```

Verify:
```sh
adb shell pm dump com.nook.partner | grep -A5 disabledComponents
# Should list: com.nook.partner.statusbar.StatusBarService
```

To re-enable:
```sh
adb shell su -c 'pm enable com.nook.partner/.statusbar.StatusBarService'
```

**Note:** `GlowLightService` (warmth control) is a separate service in
`com.nook.partner` and is NOT affected by disabling `StatusBarService`. Warmth
control continues to work after this change.

### Step 2 — Suppress SystemUI temperature warning (Layer 2)

```sh
adb shell settings put global show_temperature_warning 0
```

This persists in the Settings database across reboots but is wiped by a factory
reset. The `no_slideunlock` Magisk module's `service.sh` re-applies it on every
boot:

```sh
settings put global show_temperature_warning 0
```

---

## Safety impact of disabling StatusBarService

Disabling `StatusBarService` removes **nookPartner's** temperature monitoring layer.
The Android framework has its own independent thermal protection that remains active:

| Layer | Status after disabling StatusBarService |
|-------|-----------------------------------------|
| nookPartner warning dialog (48°C / 8°C) | **Removed** (StatusBarService disabled) |
| nookPartner soft shutdown (50°C / 5°C) | **Removed** (StatusBarService disabled) |
| SystemUI custom warning dialog | **Removed** (show_temperature_warning=0) |
| Android framework `BatteryService` thermal shutdown | **Still active** |
| Kernel thermal governor / hardware OCP | **Still active** |

The device will still shut down safely at extreme temperatures via the framework
and hardware protection layers. The nookPartner and SystemUI thresholds are
conservative early-warning layers on top of those, not the last line of defence.

---

## Related

- [statusbar-service.md](statusbar-service.md) — full `IStatusBarService` AIDL reference
