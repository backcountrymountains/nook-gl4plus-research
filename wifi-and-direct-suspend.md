# Nook Glowlight 4 Plus — WiFi Management Analysis

This document captures research into how `com.nook.partner` manages WiFi on the
Nook Glowlight 4 Plus (bnrv1300, Android 8.1) and what options exist for KOReader
to manage WiFi state without requiring `CHANGE_WIFI_STATE` permission.

Sources: decompiled APKs from the device (`nookPartner.apk`, `nookBnEreader.apk`,
`nookHub.apk`, `NookHWTest.apk`, `ctm.apk`).

---

## How nookPartner manages WiFi: "Direct Suspend"

The core mechanism is called **Direct Suspend**, gated by a `Settings.System` key:

```
power_enhance_enable  (int: 0 = off, 1 = on)
```

### Flow when a Nook reader app opens

1. App calls `EpdPowerManager.onReaderResume()` — sets a flag, schedules a 3-second timer.
2. After 3 s → `IStatusBarService.setDirectSuspend(enable=true, saveState=true, force=false)`.
3. `StatusBarService.saveNetworkState()`:
   - Saves `wifiManager.isWifiEnabled()` into `mWifiEnabledBeforeReaderResume`.
   - Saves Bluetooth enabled state into `mBTEnabledBeforeReaderResume`.
   - Calls `wifiManager.setWifiEnabled(false)` and `bluetoothAdapter.disable()`.
   - Polls `wlan.driver.status` every 500 ms (up to 5 s) until WiFi is fully down.
4. Writes `power_enhance_enable = 1` to `Settings.System`.

### Flow when the reader app pauses

After a 1-second delay → `setDirectSuspend(enable=false, restoreState=true, force=false)`:
- `StatusBarService.restoreNetworkState()` calls
  `wifiManager.setWifiEnabled(mWifiEnabledBeforeReaderResume)`.
- Clears `mWifiEnabledBeforeReaderResume = null`.
- Writes `power_enhance_enable = 0`.

### Keeping WiFi alive during a sync

`IStatusBarService.setForceKeepNetworkState(true)`:
- If direct suspend is currently active, immediately calls
  `setDirectSuspend(false, true, force=true)` to restore WiFi.
- Queues the original pending direct-suspend values.
- Sets `mKeepNetworkState = true` — any further `setDirectSuspend` calls are deferred.

`setForceKeepNetworkState(false)`:
- Clears the flag and re-applies the deferred direct-suspend values.

---

## IStatusBarService AIDL

`com.nook.partner` exposes this as an exported bound service:

```
Action:  com.nook.intent.action.statusbar
Package: com.nook.partner
Class:   com.nook.partner.statusbar.StatusBarService
```

No `android:permission` attribute — any app can bind without special permissions.

Key methods relevant to WiFi:

| Method | Description |
|--------|-------------|
| `setDirectSuspend(bool enable, bool saveOrRestore, bool force)` | Enable/disable direct suspend, optionally saving/restoring WiFi+BT state |
| `getDirectSuspend()` | Returns current `power_enhance_enable` value |
| `setForceKeepNetworkState(bool)` | Temporarily prevent WiFi suppression (for network ops) |
| `isWifiEnabledBeforeDirectSuspend()` | Returns the saved WiFi state |
| `resetWifiEnabledBeforeReaderResume()` | Clears the saved WiFi state |
| `settingsPutInt(String key, int value)` | Privileged write to `Settings.System` |
| `settingsPutString(String key, String value)` | Privileged write to `Settings.System` |

`GlowLightService` (used for warmth control) is a separate exported started service:

```
Action: action_set_color_temperature
Extra:  extra_color_temperature  (int 0–100)
```

---

## Can KOReader use this instead of CHANGE_WIFI_STATE?

### What works

- **Suppress WiFi while reading**: bind to `IStatusBarService`, call
  `setDirectSuspend(true, true, false)` — saves current state and disables WiFi.
  No `CHANGE_WIFI_STATE` permission needed in KOReader.

- **Restore WiFi for a sync/download**: call `setForceKeepNetworkState(true)` before
  the network operation, `setForceKeepNetworkState(false)` after. If nookPartner had
  suppressed WiFi, it will restore it.

- **Restore WiFi on KOReader exit**: call `setDirectSuspend(false, true, false)` in
  `onPause()`/`onStop()` to restore WiFi to whatever state it was in before KOReader
  suppressed it.

### What doesn't work

- **Turning WiFi ON from a fully-off state**: if the user had WiFi off before KOReader
  suppressed it, `setDirectSuspend(false, true)` restores it to off (correct behavior),
  but there is no path through `IStatusBarService` to turn WiFi on from scratch.
  That requires `CHANGE_WIFI_STATE`.

### Synchronization risks

The state is stored as **a single field** in `StatusBarService`
(`mWifiEnabledBeforeReaderResume`) — not a stack, not reference-counted.

| Scenario | Risk |
|----------|------|
| User manually toggles WiFi while KOReader is managing it | Saved state becomes stale; on restore KOReader may override the user's intent |
| nookBnEreader and KOReader both use direct suspend | They share one state slot; whichever calls `setDirectSuspend` last wins |
| KOReader crashes without calling `setDirectSuspend(false)` | WiFi stays suppressed in all apps until screen is cycled off/on |
| User leaves KOReader without it cleaning up in `onPause` | Same — WiFi remains off in the launcher and other apps |

### Practical verdict

For the intended use case — user leaves WiFi toggled ON in device settings,
KOReader suppresses it while reading and restores it for syncing — the direct
suspend mechanism works reliably **as long as**:

1. KOReader properly calls `setDirectSuspend(false, true, false)` on every
   `onPause()`/`onStop()`.
2. The user does not manually toggle WiFi while KOReader is in the foreground.
3. nookBnEreader is not simultaneously using the same mechanism (unlikely in practice).

The main tradeoff vs. using `CHANGE_WIFI_STATE` directly is that you cannot turn
WiFi on from a user-initiated off state. If that use case matters, `CHANGE_WIFI_STATE`
is still required.

---

## Settings.System keys of interest

| Key | Type | Description |
|-----|------|-------------|
| `power_enhance_enable` | int (0/1) | Direct suspend active flag |
| `global_2ss_set_up_ap_timeout_ms` | int | Direct suspend timeout |
| `screen_brightness` | int (0–100) | Frontlight brightness |
| `screen_brightness_color` | int (0–10) | Warmth level (written by GlowLightService after ÷10 rescaling) |
| `lockscreen_status` | int (0/1) | Lock screen enabled flag |
