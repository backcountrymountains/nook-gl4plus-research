# Nook Glowlight 4 Plus — Research Notes

Research into the internals of the **Nook Glowlight 4 Plus** (model `bnrv1300`,
Android 8.1 / AllWinner "Emperor" platform), based on decompiled factory APKs and
live device investigation.

Device identifiers:
- Model: `bnrv1300`  
- Platform: AllWinner "Emperor"  
- Android: 8.1.0 (API 27)  
- Build: `8.1.7.120_user`  
- SoC: AllWinner (3-core ARM)

---

## Documents

| Document | Topic |
|----------|-------|
| [statusbar-service.md](statusbar-service.md) | `IStatusBarService` AIDL — all 26 methods, what each does, how to bind |
| [wifi-and-direct-suspend.md](wifi-and-direct-suspend.md) | WiFi management, Direct Suspend mechanism, synchronization risks |
| [temperature-management.md](temperature-management.md) | Temperature warning dialogs and thermal shutdown — what triggers them and how to suppress them |
| [power-management.md](power-management.md) | Deep sleep via `power_enhance_enable`, `PowerManagerEx`, nopowen patch, slide-to-unlock |
| [ota-updates.md](ota-updates.md) | OTA firmware update mechanism, server URLs, and how to permanently block all update paths |

---

## Research methodology

All app-layer findings are derived from APKs decompiled with jadx from the factory
image: `nookPartner.apk`, `nookBnEreader.apk`, `nookHub.apk`, `NookHWTest.apk`,
`ctm.apk`.

Kernel and framework behaviour was verified live over ADB with root access (Magisk).

---

## Key findings at a glance

- **`com.nook.partner/StatusBarService`** is an exported bound service (no permission
  required to bind) that acts as a privileged proxy for any app — it can toggle
  WiFi/BT, write any `Settings.System` key, reboot, and control the status bar UI.
  See [statusbar-service.md](statusbar-service.md).

- **WiFi management** is best done directly via `WifiManager.setWifiEnabled()` (with
  `CHANGE_WIFI_STATE` permission) or via `su -c svc wifi enable/disable`. The
  nookPartner "Direct Suspend" mechanism uses the same underlying API.
  See [wifi-and-direct-suspend.md](wifi-and-direct-suspend.md).

- **Temperature warnings** come from `BatteryIcon` inside `StatusBarService`.
  Disabling `StatusBarService` removes the dialogs. The Android framework's own
  thermal shutdown remains active.
  See [temperature-management.md](temperature-management.md).

- **Deep sleep** between page turns is triggered by writing `power_enhance_enable`
  to `Settings.System`. The AllWinner `PowerManagerEx` framework layer watches this
  key and calls `nativeSetCpuBoostEx`. The [nopowen](https://github.com/Codereamp/nopowen)
  KOReader patch automates this on every page turn.
  See [power-management.md](power-management.md).

- **Slide-to-unlock** is implemented in a custom `PowerManagerService` baked into
  the system image — not controllable via any app or AIDL. Requires root to suppress.
  See [power-management.md](power-management.md).

- **OTA updates** are handled entirely within `com.nook.partner` by `OtaIntentService`
  (24-hour AlarmManager check) and `SideloadInstaller`. Both can be blocked via
  `pm disable` plus a `/sdcard/ota_server.conf` redirect to localhost as a fallback.
  See [ota-updates.md](ota-updates.md).
