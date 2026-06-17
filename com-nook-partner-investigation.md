# Investigation Proposal — com.nook.partner Component Documentation

Proposed follow-up to the existing research docs. All source material is already
decompiled and on disk at `/home/point/nook-decompiled/nookPartner/sources/`.

---

## Motivation

`pm enable com.nook.partner` is required when `GlowLightService` (warmth control)
is disabled. But the command re-enables the entire package — not just the one
service. We don't have a complete picture of what else starts, which receivers fire
on boot, or which components are safe to disable afterward.

The existing docs cover specific features well but there is no component-level
inventory of the package.

---

## What's already documented

| Component(s) | Covered in |
|---|---|
| `service/GlowLightService` | `eink-and-frontlight.md` |
| `statusbar/StatusBarService` — full 26-method AIDL | `statusbar-service.md` |
| `statusbar/BatteryIcon` — temperature thresholds + shutdown | `temperature-management.md` |
| `otamanager/OtaIntentService` + `SideloadInstaller` | `ota-updates.md` |
| `EpdDisplayControllerImpl` — `View.invalidate(int)` hook | `eink-and-frontlight.md` |
| WiFi Direct Suspend via `StatusBarService` | `wifi-and-direct-suspend.md` |

---

## Gaps to investigate

### Priority 1 — Directly answers "what does pm enable start?"

#### `PartnerReceiver` + `PartnerApplication`
- **Files:** `PartnerReceiver.java`, `PartnerApplication.java`
- **Question:** Which system broadcasts does `PartnerReceiver` handle, and what does
  each one start? What does `PartnerApplication.onCreate()` initialize at package
  startup?
- **Why it matters:** This is the definitive answer to what wakes up when the
  package is enabled. Every `<receiver>` with `BOOT_COMPLETED` or
  `CONNECTIVITY_CHANGE` is background activity the user didn't ask for.
- **Effort:** ~1 hr

#### GlowLight scheduling modes — `AutoMode`, `CTMMode`, `ScheduleMode`, `ManualMode`
- **Files:** `service/AutoMode.java`, `service/CTMMode.java`,
  `service/ScheduleMode.java`, `service/ManualMode.java`
- **Question:** What do the time-based and auto-warmth modes do? What
  `Settings.System` keys do they write, and on what triggers?
- **Why it matters:** Directly explains the AutoWarmth conflict noted in the
  KOReader release README — knowing which keys these modes write tells us whether
  KOReader's manual warmth writes can race with the service's scheduler.
- **Effort:** ~1 hr

### Priority 2 — Useful for a "safe to disable" component table

#### `lockscreen/LockScreenService`
- **Files:** `lockscreen/LockScreenService.java`, `LockScreen.java`,
  `LockScreenManager.java`, `LockScreenSlider.java`, `LockScreenSurfaceView.java`
- **Question:** What is nookPartner's role in slide-to-unlock, separate from the
  `PowerManagerService` layer already documented in `power-management.md`? Is
  `LockScreenService` the component that draws the slide UI, or is it a
  coordinator?
- **Effort:** ~1.5 hr

#### `power/` — low battery and sleep notification
- **Files:** `power/LowBatteryActivity.java`, `power/SleepNotificationReceiver.java`
  (`power/PowerOffScreenActivity.java` is partially covered in
  `temperature-management.md`)
- **Question:** What threshold triggers `LowBatteryActivity`? What does
  `SleepNotificationReceiver` listen for, and is it safe to disable?
- **Effort:** ~45 min

#### `usb/` — USB management
- **Files:** `usb/UsbDebuggingActivity.java`, `UsbStorageManager.java`,
  `usb/MediaFormat.java`
- **Question:** Does `UsbDebuggingActivity` replace or wrap the standard Android
  ADB authorization dialog? Can it be disabled without breaking ADB access?
- **Effort:** ~1 hr

#### `DropboxReceiver`
- **Files:** `DropboxReceiver.java`, `DropboxReceiverKt.java`
- **Question:** What does this upload and when? Dropbox here likely refers to
  Android's internal `DropBoxManager` (crash/ANR logs), not Dropbox cloud — but
  confirm. Safe to disable?
- **Effort:** ~30 min

### Priority 3 — Low relevance to KOReader use

#### `wifi/` — WiFi picker UI
- Standard Android WiFi settings UI ported into nookPartner. Not device-specific.
  Already understood via `wifi-and-direct-suspend.md`.
- **Effort:** ~1 hr (skip unless needed)

#### `bluetooth/` — Bluetooth settings UI
- Standard Bluetooth pairing UI. Not relevant to current work.
- **Effort:** ~1 hr (skip unless needed)

#### `screensaver/`, `daydream/`, `oobe/`
- Screen saver, daydream mode, and out-of-box experience. No relevance to KOReader.
- **Effort:** ~1 hr combined (skip)

---

## Proposed output

A single new file: **`com-nook-partner-components.md`**

Sections:
1. **Package startup** — `PartnerApplication` init, `PartnerReceiver` broadcast
   table
2. **GlowLight scheduling** — AutoMode / CTMMode / ScheduleMode internals,
   Settings.System keys written, conflict surface with KOReader
3. **LockScreen layer** — nookPartner's role in slide-to-unlock
4. **Power / battery activities** — low battery threshold, sleep notification
5. **USB management** — ADB dialog, storage manager
6. **Crash reporting** — DropboxReceiver
7. **Master component table** — every `<service>`, `<receiver>`, `<activity>` with
   its intent filters, whether it auto-starts, and a safe-to-disable verdict

The master table in section 7 is the primary deliverable — it extends the stub
table at the bottom of `ota-updates.md` into a complete reference.

---

## Estimated total effort

| Priority | Items | Effort |
|---|---|---|
| P1 | PartnerReceiver/Application + GlowLight modes | ~2 hr |
| P2 | LockScreen + power + USB + Dropbox | ~3.25 hr |
| P3 | WiFi/BT/screensaver/daydream/OOBE | ~3 hr (skip) |
| **P1+P2 total** | | **~5.25 hr** |

P1 alone (~2 hr) produces the `PartnerReceiver` broadcast table and GlowLight
scheduling docs, which are the most immediately useful. P2 rounds it out into a
complete component inventory.
