# Nook Glowlight 4 Plus — Temperature Management

This document covers how the device monitors battery temperature, what triggers the
warning dialog and thermal shutdown, and how to suppress the dialog without
compromising safety.

Sources: decompiled `nookPartner.apk` (`BatteryIcon.java`, `StatusBarService.java`,
`PowerOffScreenActivity.java`).

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

---

## Warning dialog

The dialog is a Nook `AlertDialog` containing a single `ImageView` with the
`ic_batttery_temperature` drawable (battery + thermometer graphic). It has one
button ("OK") that dismisses it. There is no way to suppress it short of:

- Dismissing it each time (user action), or
- Disabling `StatusBarService` (see below).

There are no `Settings.System` keys or system properties that gate this dialog.
The thresholds are hardcoded.

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

## How to suppress the warning dialog

Disable `StatusBarService` via root:

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

---

## Safety impact of disabling StatusBarService

Disabling `StatusBarService` removes **nookPartner's** temperature monitoring layer.
The Android framework has its own independent thermal protection that remains active:

| Layer | Status after disabling StatusBarService |
|-------|-----------------------------------------|
| nookPartner warning dialog (48°C / 8°C) | **Removed** |
| nookPartner soft shutdown (50°C / 5°C) | **Removed** |
| Android framework `BatteryService` thermal shutdown | **Still active** |
| Kernel thermal governor / hardware OCP | **Still active** |

The device will still shut down safely at extreme temperatures via the framework
and hardware protection layers. The nookPartner thresholds were a conservative
early-warning layer on top of those, not the last line of defence.

---

## Related

- [statusbar-service.md](statusbar-service.md) — full `IStatusBarService` AIDL reference
