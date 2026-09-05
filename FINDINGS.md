# FINDINGS — Nook Glowlight 4 Plus research

Settled questions. `[SETTLED]` act on it · `[NEGATIVE]` disproved, do not revive ·
`[SUPERSEDED]` names its replacement · `[OPEN]` known unknown · `[INHERITED]` unvalidated.

---

## Frontlight / warmth

### Why does warmth reset to cold on every unlock?    [SETTLED]
B&N's CTM layer inside `GlowLightService` runs `setupCTM()` on every `SCREEN_ON`; in mode
`-1` (`CTM_MODE_DISABLE`) it forces `COLD_LIGHT`, which is **0** on Emperor. `getCTMMode()`
**defaults to `-1` when the `ctm_mode` key is absent** (`GlowLightService.java:682`), so a
lost pref is indistinguishable from a deliberate setting. Verified 2026-08-13 on-device:
`setupCTM:-1` → `kk-1-brightness(color):0`, `screen_brightness_color` 10 → 0 across one
screen cycle. Fix and recovery: `frontlight.md` § Color Temperature Management.
Invalidated by: a firmware update changing the `getCTMMode()` default.

### Does `ctm_mode` survive an unclean shutdown?    [SETTLED]
No — and nothing restores it. It lives only in
`/data/data/com.nook.partner/shared_prefs/ctm_preference.xml`. `ACTION_ENABLE_CTM` is sent
only by B&N's glowlight UI (`GlowLightUtils.java:146`); no `BOOT_COMPLETED` receiver in
nookPartner touches CTM, so once the key is lost the device forces cold light after every
unlock, permanently. Observed after a thermal shutdown on 2026-08-02: `ctm_preference.xml`
held one key (`color_temperature=0`) while `partner.xml` and
`com.nook.partner_preferences.xml` still carried their 2025-11-04 mtimes.
**The loss mechanism itself (SharedPreferences commit unflushed at power cut) is inferred
from that file's content shape, not directly observed** — `/sys/fs/pstore` was empty and
the mtime was overwritten by the repair.

### Can warmth be repaired without root?    [SETTLED]
Yes, two intents to the exported `GlowLightService`, in this order: `action_set_ctm_mode`
with `extra_ctm_mode 0`, then `action_set_color_temperature` with `extra_color_temperature`
0–100. Verified 2026-08-13: `setupCTM:0` → `kk-1-brightness(color):10`, held across a
screen cycle. Step 1 alone leaves warmth at `DAY_LIGHT`/10 = **1** — `ManualMode`'s fallback
when `manual_color_temperature` is unset. Automated in
`NookGL4plusController.assertManualCtmMode()`.

### Does the on-device "Display Settings" app repair CTM mode?    [NEGATIVE]
No. `com.example.ctm` — the "Display Settings" entry on the launcher — holds `DEVICE_POWER`
and drives `LightsService` **directly**, bypassing `GlowLightService`'s intent API. Tested
2026-08-13 from a deliberately broken state: sliding warmth to maximum produced
`kk-1-brightness(color):3→2→1→0→9→10` and **zero `CTMService` log lines**; `ctm_mode` was
never written and warmth still went **10 → 0** across the next screen cycle. It changes the
light, not the setting that survives unlock. `NightModeSettingsFragment` would write the
mode but lives in `bn.ereader` (disabled on a KOReader device); nookPartner's `QuickSettings`
also calls `setupCTMMode()` but is reachable only from B&N's status bar — **[OPEN]**, untested.

### Does deleting `ctm_preference.xml` reproduce the cold-light symptom?    [SETTLED]
Yes — this is the direct confirmation of the root cause. Deleting only that file and killing
`com.nook.partner` (`am force-stop` does **not** work; it is persistent — `kill -9` the pid)
makes warmth reset to `0` on the next screen cycle, exactly as observed after the 2026-08-02
thermal shutdown. It also confirms the non-persistence claim: with the mode absent, KOReader's
warmth intent left `color_temperature=100` in the rewritten prefs and no
`manual_color_temperature`, matching the single-key file found in the wild.

### Is `screen_brightness_color_backup` the value CTM restores?    [NEGATIVE]
No. Set it to `6`, cycled the screen, warmth still came back `0` (2026-08-13). The reset
value is the `COLD_LIGHT` constant, not a backup key. Do not chase this setting again.

### Is `com.example.ctm` the app that resets warmth?    [NEGATIVE]
No. Its manifest declares two activities (`MainActivity`, `GlowlightActivity`) and no
service or receiver, so it cannot react to `SCREEN_ON`. `CTMService` is merely the log TAG
of `com.nook.partner.service.GlowLightService` (`GlowLightService.java:46`), which is why
the log lines appear under the nookPartner pid. **Disabling `com.example.ctm` fixes
nothing**; disabling `GlowLightService` is actively harmful — it is the only unprivileged
path to set warmth at all.

### Warmth intent scale    [SETTLED]
`extra_color_temperature` is 0–100; the service rescales to the 0–10 lm3630a hardware
range. Emperor **inverts** the named constants (`GlowLightUtils.java:38-40`):
`COLD_LIGHT=0`, `DAY_LIGHT=12`, `TUGSTEN_LIGHT=87` — the opposite of every other device.

### Does moving KOReader's warmth slider repair a broken device?    [SETTLED]
Yes. 2026-09-04, fresh KOReader process on a genuinely broken device, slider 0→5:
`Setting warmth to 1 of 10` (.143) → `CTM mode set to manual` (.149) → `CTMService:
setupCTM:0` (.183) → `backlight-color: target brightness=1` (.199). `ctm_mode=0` restored
in the prefs, held across a screen cycle. The assert fires **exactly once per process** —
slider steps 2,3,4,5 logged no further mode intent, so the latch works as designed.
This was the missing receipt the 2026-08-13 session could not get. Receipt: `8e5a883`.

### Is the CTM repair durable across a reboot?    [SETTLED]
Yes. Clean reboot with `ctm_mode=0` present: warmth still 5, prefs intact (2026-09-04).
So **one warmth-slider nudge permanently fixes the device** — until the next unclean
shutdown. Receipt: `8e5a883`.

### Does a real reboot reproduce the bug the same as `kill -9`?    [SETTLED]
Yes, identically — and with one detail `kill -9` hides. With the prefs file deleted and
the device genuinely rebooted, warmth still read 5 **immediately after boot**; only the
FIRST screen cycle broke it (`setupCTM:-1` → `brightness(color):0`, 5→0). The reset lands
on first `SCREEN_ON`, not at boot, which is exactly "resets on every unlock". The service
recreates `ctm_preference.xml` holding only `color_temperature=0` — it is the **absent
key**, not an absent file. Receipt: `8e5a883`.

### Does KOReader restore warmth at launch or resume?    [SETTLED → fixed upstream]
No, on stock code. Re-confirmed 2026-09-04 on a fresh process: launch + resume + unlock
emitted **zero** `V/Lights` lines. `AndroidPowerD:init()` only computes ranges;
`turnOnFrontlightHW()` writes warmth only when `hasStandaloneWarmth()` is true AND on an
off→on transition, and `AndroidPowerD` does not override `beforeSuspend`/`afterResume`
(unlike Kobo/Kindle), so no such transition happens at startup or resume. This is an
**Android-generic gap**, not Nook-specific — invisible where hardware retains warmth.
Fixed by `koreader/koreader#16004`. Precedent: `KoboPowerD:init` already does this
(`kobo/powerd.lua`, `self:setWarmth(self.fl_warmth, true)`).

### Would flipping `hasStandaloneWarmth()` to true give self-heal?    [NEGATIVE]
No. Falsified by reading, 2026-09-04, no build spent. The flag is consulted ONLY in
`turnOnFrontlightHW`/`turnOffFrontlightHW`; `turnOnFrontlight` early-returns when the
light is already on; there is no off→on transition at startup or across suspend/resume on
Android; `BasePowerD:new` calls only `_decideFrontlightState()`, which just reads HW state.
Flipping it would fire on a **manual frontlight toggle and nothing else**. Do not revive.
Receipt: `d4b47d2`.

### `warmth_scale` is stale during `init()` — the trap that breaks a naive fix    [SETTLED]
`BasePowerD:new()` assigns `self.warmth_scale = 100 / o.fl_warmth_max` to the **class**,
not the instance `o`, and only **after** `init()` returns. The module-level
`local AndroidPowerD = BasePowerD:new{...}` at require time has already set
`BasePowerD.warmth_scale = 1` (no `fl_warmth_max` passed → inherits the default 100).
So during `init()`, `self.warmth_scale` resolves through the metatable to that stale `1`.
Measured: `BEFORE orig_init … fl_warmth_max=100 warmth_scale=1`, `AFTER … fl_warmth_max=10
warmth_scale=1`. A guarded `if not self.warmth_scale` therefore keeps `1`,
`toNativeWarmth(100)`=100, and the controller rejects it: `W Lights: warmth value out of
range: 100`, warmth stays 0. **Assign `warmth_scale` unconditionally in `init()`** — which
is why `KoboPowerD:init` does. Receipts: `d4b47d2`, `67f3b0b`.

### Does KOReader clobber CTM AUTO/SCHEDULE, and does it matter?    [SETTLED]
It clobbers (mode 1 → 0, with the service recording `pre_ctm_mode=1`), but it **does not
matter**, so no restore logic is needed. Measured 2026-09-04: AUTO (1) + warmth 30 survived
a screen cycle (`setupCTM:1` → `color:3`); SCHEDULE (2) + warmth 70 likewise (`setupCTM:2`
→ `color:7`). In modes 1/2 the service re-applies the stored `color_temperature`, which is
what our warmth intent writes — so **only mode `-1` is broken**; 0, 1 and 2 all behave the
same for KOReader. Supersedes the old "decide clobber-vs-restore" open question.
Receipts: `6ad9d10`, `2b598af`.

### `bn.ereader` is always disabled — design to it    [SETTLED]
KOReader and the stock reader are mutually exclusive (`bn.ereader` takes over the whole
device), so every KOReader user has disabled it. Verified on-device 2026-09-04:
`pm list packages -d` returns exactly `bn.ereader` and `com.bn.nook.hub`, and
`com.nook.partner` is ENABLED. Consequences: CTM AUTO/SCHEDULE cannot compute anything
(their schedule comes from `bn.ereader/...DeviceLocationService` → `Unable to start service
… not found`), so clobbering to manual costs nothing; and the `setupAutoModeGPB` power
caveat is inert by construction. **Do not engineer for a `bn.ereader`-enabled device.**
Receipt: `2b598af`.

### Does asserting CTM mode cause a visible warmth flash?    [SETTLED]
Yes, small and real. Asserting the mode makes the service re-apply its **own stored value**
before ours lands. Measured 2026-09-04 (stored 10, user asked 9): request `.335`, assert
`.340`, `setupCTM:0` `.378`, hardware driven to the stored **10** at `.392`, correct 9 only
at `.428` — wrong value on screen ~36 ms, ~57 ms after the request. Not removed by the
startup-restore fix, only moved to launch; there the stored value on a broken device is 0,
so it reads as a brief cold flicker during startup redraw. Receipts: `8e5a883`, `d4b47d2`.

### Which CTM modes start the `bn.ereader` location service on SCREEN_ON?    [SETTLED]
Modes 0, 1 and 2 all do; only `-1` short-circuits. Measured 2026-09-04 in mode 0: 2
`action_get_device_location` attempts across 2 screen cycles. So the power cost belongs to
the **`-1 → 0` repair**, not to the clobber (`1→0` / `2→0` change nothing). Inert on any
supported device since `bn.ereader` is disabled. Receipt: `6ad9d10`.

---

## Upstream / tooling

### Is anyone else fixing the CTM warmth reset upstream?    [SETTLED]
No. Searched 2026-09-04 with `gh` (validated against a control query that does return
14574, so the empty results are real): no issue or PR anywhere in the `koreader` org
mentions `ctm_mode`, `GlowLightService`, or a CTM warmth reset; none of the 10 open
`android-luajit-launcher` PRs touch Nook. `NookGL4plusController.kt` has exactly ONE
upstream commit ever — `d1be9af` (#592, 2026-06-19), ours — and `origin/master`'s copy is
byte-identical to our fix's base. **Issue `koreader/koreader#14574` is our own FR** ("Add
Brightness and Warmth Light control for … BNRV-1300", CLOSED, `enhancement`); the
`see …/14574` line in the controller predates the fix and points at that device-support
request, NOT at a bug report. Receipt: `d4e1cf7`.

### Can KOReader's Lua be patched on-device without rebuilding the APK?    [SETTLED]
Yes — this removes the Docker build from the test loop entirely. Two routes:
1. **Direct file edit** (tests the real diff): the tree lives at
   `/data/data/org.koreader.launcher/files/frontend/…`, owned by the app uid, editable with
   `su`. Back up to `.orig`, `cat` the new file over it, restore afterwards.
2. **Userpatch** (non-destructive): drop `<priority>[digits]-name.lua` in
   `/sdcard/koreader/patches/`; the name must match `^<priority>%d*%-`. Priorities:
   `0`=early_once, `1`=early (reader.lua:27, **before** `Device` at :157), `2`=late,
   `8`/`9`=exit. `G_reader_settings` exists from reader.lua:39, so it is available inside a
   wrapped `AndroidPowerD:init`.
Confirm the device tree matches your checkout first — it was byte-identical to `4bd308b3a`,
which is the installed `versionName`. Receipt: `d4b47d2`.

### Driving the KOReader UI over adb on this device    [SETTLED]
Expensive to re-derive; all measured 2026-09-04 at 1404x1872.
- `activate_menu = "swipe"` in `settings.reader.lua` — **taps and KEYCODE_MENU all page
  FORWARD**. The menu opens by swiping DOWN from the top edge: `input swipe 702 8 702 500 400`.
- Frontlight = Settings **gear** tab `(435,60)`, first item `(210,182)` — same in both
  reader and file manager. Warmth slider `y=961`, track `x` 185→1220. OK `(1162,1041)`,
  CANCEL `(1019,1041)` — **CANCEL does not revert** the warmth already applied.
- Page turns: taps go FORWARD anywhere; **right-swipe** (`input swipe 300 900 1100 900 300`)
  goes back.
- KOReader's own sleep screen unlock arrow is at **y≈1772** (the text at y≈1800 is not
  draggable): `input swipe 420 1772 1080 1772 800`. While that screen is up KOReader
  re-suspends within ~20 s and **`stay_on_while_plugged_in` / `svc power stayon` do NOT
  hold it** (custom `PowerManagerEx`); after a successful unlock the normal 5-min timeout
  applies.
- `adb logcat -c` fails on this device ("failed to clear the 'main' log") — use `-t N` or
  `-T <ts>` windows instead.
Receipt: `d4b47d2`.

### `gh pr edit` is broken against these repos    [SETTLED]
It fails with a GraphQL Projects-classic deprecation error and silently does not write.
Use REST instead: `gh api -X PATCH repos/<owner>/<repo>/pulls/<n> -f body="$(cat file)"`.
Verified 2026-09-04 while cross-linking the two PRs. Receipt: `67f3b0b`.
