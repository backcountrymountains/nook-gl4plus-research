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
| [eink-and-frontlight.md](eink-and-frontlight.md) | E-ink refresh via `View.invalidate(int)` hook; brightness via `Settings.System`; warmth via `GlowLightService` |
| [hwc-hal-reverse-engineering.md](hwc-hal-reverse-engineering.md) | Full RE of `hwcomposer.virgo.so`, `libgui.so`, `libsurfaceflinger.so`, and framework VDEX — call chain from `SurfaceControl.setRefreshMode` down to `layer->refreshMode` at HWC struct offset 0x24 |
| [handoff-surfacecontrol-path.md](handoff-surfacecontrol-path.md) | Test procedure and decision tree for the new no-root SurfaceControl waveform path (GLR16 capable) |

---

## Environment

**ADB setup — Windows USB bridge to WSL**

The Nook is connected to a Windows host via USB. WSL2 cannot access USB devices
directly, so ADB is bridged: the Windows ADB server connects to the device over USB
and WSL connects to that server over TCP.

All ADB commands from WSL use:
```
adb -H 192.168.1.92 -P 5037 <command>
```

**Consequence:** unplugging USB from the Nook also breaks ADB connectivity — there
is no WiFi ADB fallback. Any test that requires USB to be unplugged must complete all
ADB setup *before* the unplug, write output to the device filesystem (`/sdcard/` or
`/data/local/tmp/`), and pull results after USB is reconnected.

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

- **E-ink refresh** uses a hidden B&N-customized AOSP hook: `View.invalidate(int)` routes
  the integer argument as an EPD waveform command to the display driver. KOReader uses
  `GC16 | NO_MERGE` for all updates (full-quality only; no partial waveform). **Brightness**
  is set via `Settings.System.SCREEN_BRIGHTNESS` (0–100 scale); **warmth** is set by
  sending an intent to `com.nook.partner/.service.GlowLightService`, which holds
  `DEVICE_POWER` and drives the LM3630A chip — no root required.
  See [eink-and-frontlight.md](eink-and-frontlight.md).

- **Unprivileged waveform control** is available via `android.view.SurfaceControl.setRefreshMode(int)`,
  a B&N-added `@hide` method that routes through SurfaceFlinger → `hwcomposer.virgo.so`
  → `layer->refreshMode` (Layer struct offset 0x24) — no permission gate found at any layer.
  This path supports **GLR16 (REAGL)** via HWC's full `/dev/disp` ioctl context, unlike
  the sysfs `force_update_mode` node which silently ignores `0x40`. Whether the path is
  reachable on this firmware depends on whether B&N backported `ViewRootImpl.mSurfaceControl`
  from AOSP Android 10 — determined at runtime by the log line in KOReader.
  See [hwc-hal-reverse-engineering.md](hwc-hal-reverse-engineering.md).
