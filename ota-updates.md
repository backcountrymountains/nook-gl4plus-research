# Nook Glowlight 4 Plus — OTA Firmware Updates

This document covers how the device checks for and applies OTA firmware updates,
and how to permanently block all update paths.

Sources: decompiled `nookPartner.apk` (`otamanager/` package), live device
investigation via ADB.

---

## Update mechanism overview

All firmware OTA logic lives in `com.nook.partner`. There is no separate OTA
package — it is a set of components within the main nookPartner APK.

### Check schedule

`OtaIntentService` checks for updates once every 24 hours
(`PERIODIC_CHECK_INTERVAL = 86400000 ms`). The check is scheduled via
`AlarmManager.setAndAllowWhileIdle()` so it fires even while the device is idle.
A minimum re-check interval of 1 hour is enforced
(`MIN_INTERVAL_OTA_CHECK = 3600000 ms`).

The last check time is stored in SharedPreferences under the key
`nook_last_ota_check`.

### Boot trigger

`OtaIntentService$BootCompleteReceiver` is a `BroadcastReceiver` registered for
`android.intent.action.BOOT_COMPLETED`. On every boot it starts `OtaIntentService`,
which re-schedules the next 24-hour alarm.

### Update check flow

1. `OtaIntentService` starts and calls `OtaManager.checkOtaServer()`.
2. `OtaManifest` fetches a JSON manifest from the OTA server (see URLs below).
3. If a newer version is found, `OtaManager.downloadOtaPackage()` downloads the
   ZIP to the download cache directory.
4. The package is verified and applied via the recovery mechanism.

### Sideload path

`SideloadInstaller` is a `BroadcastReceiver` that handles OTA packages pushed
manually to the device (e.g. placed on the SD card or sent via intent). It operates
independently of the network check path.

---

## OTA server URLs

Defined in `OtaManifest.java`:

```
DEFAULT_OTA_SERVER_URL = "https://www.nook.com/services/cms/doc/epd_ota/{model}_manifest_rel.json"
ENG_OTA_SERVER_URL     = "https://storage.googleapis.com/{model}-ota/manifest.json"
```

Where `{model}` is the device model name (e.g. `bnrv1300`).

### Built-in server override

If the file `/sdcard/ota_server.conf` exists, `OtaManifest` reads the server URL
from its first line instead of using the hardcoded defaults:

```java
if (configFile.exists()) {
    this.mServerURL = new URL(bufferedReader.readLine());
}
```

This is a device-intended override mechanism (likely for engineering/testing). It
can be used to redirect update checks to a non-existent endpoint.

---

## Components to disable

| Component | Type | Role |
|-----------|------|------|
| `com.nook.partner.otamanager.OtaIntentService` | Service | Performs update checks and downloads |
| `com.nook.partner.otamanager.OtaIntentService$BootCompleteReceiver` | BroadcastReceiver | Starts OtaIntentService on boot |
| `com.nook.partner.otamanager.SideloadInstaller` | BroadcastReceiver | Handles manually-pushed OTA packages |
| `com.nook.partner.oobe.OobeOtaActivity` | Activity | OTA UI shown during OOBE |

---

## How to block all OTA updates

Two complementary layers are recommended: disabling the components (primary) and
redirecting the server URL (fallback).

### Layer 1 — Disable OTA components

```sh
adb shell su -c 'pm disable com.nook.partner/.otamanager.OtaIntentService'
adb shell su -c 'pm disable com.nook.partner/.otamanager.SideloadInstaller'
adb shell su -c 'pm disable com.nook.partner/.oobe.OobeOtaActivity'
```

Note: `OtaIntentService$BootCompleteReceiver` is an inner class that `pm disable`
cannot target independently. Disabling `OtaIntentService` is sufficient — when the
receiver fires on boot it will attempt to start the disabled service, which Android
silently rejects.

### Layer 2 — Redirect the OTA server to localhost

```sh
adb shell "echo 'http://127.0.0.1/' > /sdcard/ota_server.conf"
```

This uses the device's own built-in override mechanism. Even if the OTA components
are ever re-enabled, all update checks will be directed to localhost and fail
gracefully.

### Verify

```sh
adb shell dumpsys package com.nook.partner | grep -A10 disabledComponents
# Should include:
#   com.nook.partner.otamanager.OtaIntentService
#   com.nook.partner.otamanager.SideloadInstaller
#   com.nook.partner.oobe.OobeOtaActivity

adb shell cat /sdcard/ota_server.conf
# Should output: http://127.0.0.1/
```

### To re-enable updates

```sh
adb shell su -c 'pm enable com.nook.partner/.otamanager.OtaIntentService'
adb shell su -c 'pm enable com.nook.partner/.otamanager.SideloadInstaller'
adb shell su -c 'pm enable com.nook.partner/.oobe.OobeOtaActivity'
adb shell rm /sdcard/ota_server.conf
```

---

## Full disabled component list (as of this research)

For reference, the complete set of disabled `com.nook.partner` components after
applying all changes documented across this repo:

| Component | Reason disabled |
|-----------|----------------|
| `com.nook.partner.statusbar.StatusBarService` | Eliminates temperature warning dialogs; see [temperature-management.md](temperature-management.md) |
| `com.nook.partner.FacadeLauncherActivity` | Nook launcher — replaced by third-party launcher |
| `com.nook.partner.OobeLauncherActivity` | OOBE launcher — not needed |
| `com.nook.partner.oobe.OobeOtaActivity` | OTA UI — blocked as part of update prevention |
| `com.nook.partner.otamanager.OtaIntentService` | Blocks scheduled firmware update checks |
| `com.nook.partner.otamanager.SideloadInstaller` | Blocks manually-pushed OTA packages |
