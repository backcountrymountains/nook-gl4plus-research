# STATE — session cursor

Last updated: 2026-08-13. Topic: **warmth resets to cold on every unlock** on the
Nook GL4 Plus, its root cause, a KOReader-side fix, and how far that fix is verified.

Settled facts live in `FINDINGS.md` — read it first, it has the receipts.
This file is only what is *in flight*.

---

## Where the work stands

Root cause is **fully settled and reproduced end to end** (see `FINDINGS.md`).
The KOReader fix is **written, compiling, and half-verified**. Do not describe it
as "the fix" in a PR yet — one of its two claims is falsified.

| Claim | Status |
|-------|--------|
| Root cause: CTM mode `-1` forces `COLD_LIGHT` on every `SCREEN_ON` | **verified** — deleting `ctm_preference.xml` alone reproduces it |
| Two-intent ADB repair works | **verified** repeatedly, survives screen cycles |
| Kotlin `assertManualCtmMode()` executes and is handled | **verified** — `V/Lights: CTM mode set to manual` → `setupCTM:0` |
| KOReader repairs the device on launch or resume | **FALSIFIED** — see Dead ends |
| Repair from a genuinely broken state via the warmth slider | **not yet tested** — user was going to do this |

---

## Code, branches, commits

**The fix** — `koreader/platform/android/luajit-launcher`, branch **`nook-gl4plus-ctmfix`**,
commit **`81c797b`**, based on `a22c7a7` (`nook-personal`).
Also exists as `cb48287` on `nook-gl4plus-epd` (same diff, different base).
One file: `app/src/main/java/org/koreader/launcher/device/lights/NookGL4plusController.kt`,
+39/-1. Adds `assertManualCtmMode()`, called once per process from `setWarmth()`
immediately before the warmth write.

**Docs** — `nook-gl4plus-research`: `b274065` (mechanism + recovery + `FINDINGS.md` created),
`0c5d2bd` (disproving the on-device UI). `koreader-nook-gl4plus`: `a90b46c`, `3ca5638`.

**Uncommitted at wrap-up:** `koreader` has a dirty submodule pointer
(`M platform/android/luajit-launcher`) because the working tree is on the
`nook-gl4plus-ctmfix` branch. Left dirty deliberately — `koreader` is on `master`
and this session did not commit to master. Also untracked build output
(`build/`, `ko-ctmfix*-signed.apk`).

---

## Exact next step

The trigger point is wrong. `assertManualCtmMode()` only runs inside `setWarmth()`,
and **nothing calls `setWarmth()` at launch or resume**, so the fix never self-heals.
Decide between:

- **(a) Two-part PR** — keep the launcher change, and add a KOReader-side warmth
  restore at init (`AndroidPowerD:init()` pushing saved `frontlight_warmth` to
  hardware, the way Kobo/Tolino do). This is what `frontlight.md` previously
  *assumed* already existed; it does not.
- **(b) Move the assert** into a path that actually runs at startup. Note the trap:
  asserting the mode makes CTM re-apply its *own* stored value, so any assert must
  be paired with a warmth write or it will change the light.

Before either, get the missing receipt: break the device, nudge the warmth slider
in KOReader, confirm `ctm_mode` reappears and survives a screen cycle.

---

## Reproducing the broken state (needed for every test)

```bash
A="adb -H 192.168.1.92 -P 5037"
$A shell "su -c 'rm -f /data/data/com.nook.partner/shared_prefs/ctm_preference.xml'"
$A shell "su -c 'kill -9 \$(pidof com.nook.partner)'"    # am force-stop does NOT work: PERSISTENT
sleep 4
$A shell input keyevent 26; sleep 3; $A shell input keyevent 224   # wake, not toggle
$A shell settings get system screen_brightness_color               # -> 0 when broken
```

Repair (idempotent, no root, order matters):

```bash
$A shell "am startservice -n com.nook.partner/.service.GlowLightService -a action_set_ctm_mode --ei extra_ctm_mode 0"
$A shell "am startservice -n com.nook.partner/.service.GlowLightService -a action_set_color_temperature --ei extra_color_temperature 100"
```

---

## Dead ends — do not re-derive these

- **KOReader does not repair on launch or resume.** Tested 2026-08-13 against a
  broken device: launched, ran, slept, woke — logcat shows **no** `V/Lights` line
  at all, neither warmth nor brightness. `BasePowerD:new()` only *reads* warmth
  (`o.fl_warmth = o:frontlightWarmthHW()`), `hasStandaloneWarmth()` is `false`, so
  `turnOnFrontlightHW()` skips warmth too. Warmth stayed `0`.
- **`com.example.ctm` ("Display Settings") does not repair anything.** It holds
  `DEVICE_POWER` and drives `LightsService` directly, emitting zero `CTMService`
  lines. Full entry in `FINDINGS.md`.
- **`screen_brightness_color_backup` is not the restored value.** Set it to 6,
  still got 0.
- **`com.nook.partner` must stay ENABLED.** Disabling it kills `GlowLightService`
  and warmth entirely. What KOReader users disable is `bn.ereader` and
  `com.bn.nook.hub` — confirmed on this device via `pm list packages -d`.
- **`am force-stop com.nook.partner` is a no-op** — the package is `PERSISTENT`.
  Kill it by pid.

---

## Landmines found in the build/repo (unrelated to the fix, all real)

- **`koreader` master does not build a working APK.** Its submodule pointer
  `da919d8` has no `isWifiEnabled`, but `frontend/device/android/device.lua:339`
  calls `android.isWifiEnabled()` → instant crash at startup:
  `E/NativeThread: Failed to run script: ... attempt to call field 'isWifiEnabled' (a nil value)`.
  Build against `nook-personal` (`a22c7a7`), which is a superset (has `da919d8` as
  an ancestor, plus WiFi + EPD + lights). **Unfixed.**
- **`koreader-nook-gl4plus/README.md` build section is wrong twice**: says
  `ANDROID_ARCH=arm64` (device is `armeabi-v7a` — an arm64 APK will not install),
  and omits that the output APK is **unsigned**. **Unfixed.**
- Working build recipe, all four gotchas included:
  ```bash
  docker run --rm -u 0:0 -v /home/point/nook/koreader:/src -w /src \
    -e BASH_ENV=/home/ko/.bashrc -e HOME=/home/ko koreader/koandroid:0.9.1-22.04 \
    bash -c "git config --global --add safe.directory '*'; \
             make TARGET=android ANDROID_ARCH=arm ANDROID_VERSION=127845 \
                  OUTPUT_DIR=build INSTALL_DIR=install update; \
             rc=\$?; chown -R 1000:1000 /src; exit \$rc"
  # then zipalign + apksigner with ~/.android/debug.keystore (alias androiddebugkey, pass android)
  ```
  - container user `ko` is uid **1001**, host is 1000 → run as root, `chown` back
  - git refuses the repo as root → `safe.directory '*'` **in a config file**
    (`GIT_CONFIG_*` env is ignored for this key), else `versCode` is empty and
    gradle dies with `For input string: ""`
  - `ANDROID_VERSION` must exceed the installed versionCode or install fails with
    `INSTALL_FAILED_VERSION_DOWNGRADE` (`-d` does not help; release build).
    Last used **127845**; installed on device is **1278441**, so go higher.

---

## Remaining tests before the PR

1. Repair from a genuinely broken state via the warmth slider (**missing receipt**).
2. A real reboot rather than `kill -9` — the actual bug scenario.
3. Wake from `power_enhance_enable` deep sleep, not just a screen cycle.
4. The warm flash: mode assert re-applies the stored value ~12ms before our write
   (`color:10` → `color:5` observed). A user wanting warmth **0** would see a flash
   of full warm light at every launch.
5. `com.nook.partner` disabled → `startService` returns null, we log and leave
   `ctmModeAsserted` false, so it retries on every warmth change. Confirm no crash;
   decide whether the retry is intended.
6. CTM in AUTO/SCHEDULE (mode 1/2) → we silently clobber to manual. Decide:
   document it, or probe first. Probe option: `modeChange()` broadcasts
   `action_ctm_mode_CHANGE` carrying the current mode, and it is **not** a protected
   broadcast, so KOReader can receive it; our existing warmth intent already
   triggers it. Untested.
7. Code-review nit, no device needed: `ctmModeAsserted` is `@Volatile`, so two
   threads can both pass the guard and send duplicate intents. Harmless (idempotent)
   but `AtomicBoolean.compareAndSet` avoids the comment.

**Power implications are settled** — one short-lived intent per process to an
already-`PERSISTENT` service, no wakelock, no polling. One caveat: mode `0` attempts
`setupAutoModeGPB()` on every `SCREEN_ON` (mode `-1` short-circuits). Inert here
(`bn.ereader` disabled → `Unable to start service ... not found`), but on a device
with `bn.ereader` enabled it starts a location service on every wake. Mention in the PR.

---

## Upstream / PR logistics

- Fix belongs in `koreader/android-luajit-launcher`. Remotes are already set:
  `origin` = koreader, `fork` = backcountrymountains.
- Our fix's base file is **byte-identical to `origin/master`**, so `81c797b`
  cherry-picks cleanly onto a fresh upstream branch. Do that rather than carrying
  local history.
- **Do not carry `286c149`** (local "Add EPD waveform controller") into any PR — it
  is already upstream as `f1ab2b1` (#597), and upstream's version has 202 lines ours
  lacks (`SunxiEPDController`, `LenovoSmartPaperEPDController`).
- Upstream launcher is 10 commits ahead; `koreader` is **154** behind (last fetch
  before today was Jun 18). `1a7fe5a` ("Fix EPD full refresh not working", #608)
  touches the EPD path — read it when rebasing the EPD work.
- Sequence agreed: verify the fix on the current known-good base → cut a clean PR
  branch off fresh `origin/master` with just the fix → rebuild and re-verify from
  that → only then move the daily build onto the new base.
- Nothing has been pushed. No issue or PR filed. Drafts not yet written.

---

## Device state at wrap-up

Working. `ctm_mode=0`, warmth holding across screen cycles. Installed KOReader is
`ko-ctmfix3-signed.apk` — built from `nook-personal` + the fix, versionCode
**1278441**. Warmth slider was left at **2 of 10** by the last test, not 10.
`stay_on_while_plugged_in` was set during testing and **reverted to 0**.
`screen_brightness_color_backup` was set to 6 during testing and **reverted to 0**.

---

## Log — 2026-09-04

- 16:42 Cursor claim "warmth slider left at 2 of 10" was WRONG at session start —
  device read `screen_brightness_color=10`, `ctm_mode=0`, `color_temperature=100`.
- 16:46 Instrument validated on a known-good device: synthetic `input swipe` on the
  warmth slider produces `V/Lights: Setting warmth to N of 10` (10→5). No assert line,
  because the long-running KOReader process had already consumed the once-per-process latch.
- 16:47 Broken state via `kill -9`: service recreates `ctm_preference.xml` containing
  ONLY `color_temperature=0` — **no `ctm_mode` key**. Cleaner receipt than "file missing":
  it is the absent key, not the absent file, that yields `getCTMMode() → -1`.
- 16:48 Re-confirmed the falsified claim on a fresh process: launch + resume + unlock
  emitted **zero** `V/Lights` lines. Wake logged `CTMService: setupCTM:-1` →
  `brightness(color):0`.
- 16:53 **TEST 1 PASSES — the missing receipt.** Fresh KOReader (pid 19032) on a broken
  device, warmth slider dragged 0→5:
  `Setting warmth to 1 of 10` (.143) → `CTM mode set to manual` (.149) →
  `CTMService: setupCTM:0` (.183) → `backlight-color: target brightness=1` (.199).
  `ctm_mode=0` restored in the XML. Assert fired exactly ONCE — slider steps 2,3,4,5
  logged no assert line, so the once-per-process latch behaves as designed.
- 16:54 Repair survives a screen cycle: warmth held at 5, `setupCTM:0` on wake.
- 16:57 **TEST 2a** — repair is durable across a clean reboot (warmth 5, `ctm_mode=0`).
- 16:58 **TEST 2b — a real reboot reproduces the bug identically to `kill -9`.** With the
  file deleted then rebooted: warmth still read 5 immediately after boot, and only the
  FIRST screen cycle broke it — `setupCTM:-1` → `brightness(color):0`, 5→0. The reset
  lands on first SCREEN_ON, not at boot, which is exactly "resets on every unlock".
- 17:00 **TEST 6 — AUTO mode IS silently clobbered.** CTM set to mode 1, fresh KOReader,
  slider moved: `ctm_mode` 1→0. B&N's service recorded `pre_ctm_mode=1`, so the prior
  mode is recoverable if the PR chooses to restore it rather than clobber.
- 17:00 **TEST 4 — the warm flash is real, and measured.** Stored 10, user asked 9:
  request at .335, assert .340, `setupCTM:0` .378, hardware driven to the STORED **10**
  at .392, correct value 9 only at .428. Wrong value on screen ~36 ms, ~57 ms after the
  request. Stored 100 + target 0 would be a full-warm flash on every first warmth change.
- Navigation recipe (expensive to derive, needed for every UI test):
  `activate_menu = "swipe"` — taps and KEYCODE_MENU all page FORWARD. Menu opens by
  swiping down from the top edge. Frontlight = Settings **gear** tab (435,60), first
  item (210,182), in BOTH reader and file manager. Warmth slider y=961, track x 185→1220.
  KOReader's own sleep screen unlock arrow is at **y≈1772** (not 1800 — the text is at
  1800 and swiping there does nothing); drag (420,1772)→(1080,1772).
  While that sleep screen is up KOReader re-suspends the device within ~20 s and
  `stay_on_while_plugged_in`/`svc power stayon` do NOT hold it (custom `PowerManagerEx`);
  after a successful unlock the normal 5-min timeout applies. `logcat -c` fails on this
  device ("failed to clear the 'main' log") — use `-t N` / `-T <ts>` windows instead.
- NOT tested this session: **#5** (`com.nook.partner` disabled → `startService` null) —
  skipped deliberately, it needs disabling the package the ledger says must stay ENABLED.
  **#3** deep-sleep wake is only partially covered: the device does suspend hard
  (`PowerManagerEx`) and warmth held across those cycles, but `power_enhance_enable`
  reads `null` on this build, so the named knob was never exercised.
- 17:20 **Upstream is empty — nobody else is working on this.** `gh` search (validated
  against a known-good control that does return 14574, so the empty results are real):
  no issue or PR anywhere in the `koreader` org mentions `ctm_mode`, `GlowLightService`,
  or a CTM warmth reset. None of the 10 open `android-luajit-launcher` PRs touch Nook.
  `NookGL4plusController.kt` has exactly ONE upstream commit ever — `d1be9af` (#592,
  2026-06-19), authored by us — and `origin/master`'s copy is byte-identical to our
  fix's base, so it is untouched since. `origin/master` is **18** ahead of `a22c7a7`
  (cursor said 10).
- 17:20 **Issue 14574 is OUR OWN FR**, "FR: Add Brightness and Warmth Light control for
  Nook Glowlight 4 plus BNRV-1300", opened 2025-11-05, CLOSED, label `enhancement`. The
  `see .../issues/14574` line in the controller predates our fix and points at the
  device-support request, NOT at a report of the warmth reset. **No upstream issue
  documents this bug** — one needs filing before or with the PR.
- 17:22 Precedent found: **koreader#5465** (2019, Kobo A1) "After a koreader restart the
  frontlight warmth resets to 0 ... I just have to adjust it twice to get it back."
  NiLuJe's fix coupled warmth into `KoboPowerD:setIntensityHW` for devices with natural
  light but no mixer. Same shape as ours; useful to cite in the PR.
- 17:25 **`hasStandaloneWarmth() = false` in our controller looks like a misdeclaration —
  possible one-line option (c).** `AndroidPowerD:turnOnFrontlightHW()`/`turnOffFrontlightHW()`
  write warmth ONLY `if android.hasStandaloneWarmth()`, which is why nothing writes warmth
  at startup. Our `setBrightness` writes `Settings.System.SCREEN_BRIGHTNESS` while
  `setWarmth` sends an independent service intent — fully separate mechanisms. The two
  controllers that DO return `true` (`OnyxWarmthController`, `OnyxPalma2ProController`)
  qualify on exactly that criterion: separate sysfs files for brightness vs warmth.
  Flipping the flag would make `turnOnFrontlightHW()` fire our assert paired with the
  user's SAVED warmth — satisfying the pairing constraint AND removing the flash.
  **UNVERIFIED, three named risks:** (1) `turnOnFrontlightHW` only runs on an off→on
  frontlight transition, so it may not fire at every launch; (2) `turnOffFrontlightHW`
  would then write `fl_warmth_min`=0, which under CTM manual mode PERSISTS 0 as
  `manual_color_temperature` — a possible new regression; (3) scaling asymmetry —
  `turnOnFrontlightHW` sends `fl_warmth / warm_diff` (0-10) while `setWarmthHW` sends
  `warmth` raw, and the controller range-checks against `WARMTH_MAX`=10. Test before believing.
- 17:26 **Option (c) — flipping `hasStandaloneWarmth()` — is DEAD. Falsified by reading,
  no build needed.** The flag is consulted ONLY in `turnOnFrontlightHW`/`turnOffFrontlightHW`;
  `turnOnFrontlight` early-returns when the light is already on; `AndroidPowerD` does NOT
  override `beforeSuspend`/`afterResume` (unlike Kobo/Kindle) and the base versions never
  touch the frontlight, so there is no off→on transition across suspend/resume; and
  `BasePowerD:new` calls only `_decideFrontlightState()`, which just reads `isFrontlightOnHW()`.
  Flipping it would fire only on a MANUAL frontlight toggle. Risk (1) was fatal; risk (3),
  the scaling asymmetry, was a false alarm (`warmth_scale`/`toNativeWarmth` handle it).
- 17:23 **Option (a) WORKS — self-heal proven on hardware, no rebuild.** KOReader's Lua
  lives at `/data/data/org.koreader.launcher/files/` AND userpatches run from
  `/sdcard/koreader/patches/` (`^<priority>%d*%-` name match; `early`="1" runs at
  reader.lua:27, before `Device` at :157; `G_reader_settings` exists by :39). Device Lua
  verified byte-identical to checkout `4bd308b3a` = installed versionName. A `1-*.lua`
  userpatch wrapping `AndroidPowerD:init` to push the saved warmth:
  broken device (warmth 0) → launch KOReader → **warmth restored to 10 with NO slider
  touch**, `Setting warmth to 10 of 10` → `CTM mode set to manual` → `setupCTM:0`, and it
  survived a screen cycle with `ctm_mode=0`, `color_temperature=100` persisted.
- 17:25 **Trap that any option-(a) implementation MUST handle — upstream bug.**
  `BasePowerD:new` line 38 does `self.warmth_scale = 100 / o.fl_warmth_max`, writing to the
  CLASS table, not the instance `o`. `generic/device.lua:240` first builds a *generic* powerd
  whose `fl_warmth_max` is the default 100, so `BasePowerD.warmth_scale` becomes **1**;
  `AndroidPowerD:init` then inherits that stale 1 through the metatable (measured:
  `BEFORE orig_init ... fl_warmth_max=100 warmth_scale=1`, `AFTER ... fl_warmth_max=10
  warmth_scale=1`). A guarded `if not self.warmth_scale` therefore silently keeps 1, so
  `toNativeWarmth(100)`=100 and the controller rejects it — observed as
  `W Lights: warmth value out of range: 100`, and warmth stayed 0. **Assign
  `warmth_scale` UNCONDITIONALLY in init**, which is exactly what `KoboPowerD:init` does
  (kobo/powerd.lua:160). My first attempt failed on precisely this; v2 fixed it.
  My lazy-lights-init hypothesis for the same symptom was WRONG — `hasNL=true` both
  before and after `orig_init`.
- 17:22 Upstream precedent for (a): `KoboPowerD:init` already does
  `if self:isFrontlightOnHW() then ... self:setWarmth(self.fl_warmth, true)`, sourcing the
  value from `G_reader_settings:readSetting("frontlight_warmth")` via `_syncKoboLightOnStart`.
  `AndroidPowerD:init()` has NO equivalent — it only computes ranges. That is the real gap,
  and it is an ANDROID-GENERIC gap, not Nook-specific; it is invisible on devices whose
  hardware retains warmth, and only bites here because CTM actively overwrites it.
- Test vehicle was REMOVED from the device (`/sdcard/koreader/patches/1-nook-ctm-warmth-restore.lua`);
  only the pre-existing `2111-nook-gl4plus-deepsleep.lua` remains. Not offered as a
  permanent install — ask the user first.
- 17:38 **Clobber-vs-restore, measured. Only mode -1 is broken; 1 and 2 are FINE.**
  Set CTM to AUTO (1) + warmth 30 → survived screen cycle (`setupCTM:1` re-applied
  `color_temperature=30` → `color:3`). Set SCHEDULE (2) + warmth 70 → likewise held
  (`setupCTM:2` → `color:7`). So in modes 1/2 the service re-applies the STORED
  `color_temperature`, which is exactly what our warmth intent writes — KOReader's warmth
  control works fine without asserting manual. **The clobber buys nothing functionally;
  it is only needed for -1.** (In 1/2 the write updates `color_temperature` but leaves
  `manual_color_temperature` alone; in 0 it updates both.)
- 17:38 **Power caveat re-scoped — the cursor's claim is right but applies to the REPAIR,
  not the clobber.** `Unable to start service ... bn.ereader/...DeviceLocationService`
  fires on every SCREEN_ON in modes 0, 1 AND 2 alike (measured: 2 attempts across 2 cycles
  in mode 0). Only -1 short-circuits. So `-1→0` adds a per-wake location attempt (inert
  here, real on a device with `bn.ereader` enabled); `1→0` / `2→0` change nothing.
- 17:39 **"Assert only when broken" IS implementable.** `dumpsys activity broadcasts`
  shows `action_ctm_mode_CHANGE` really is broadcast, `flg=0x10 (has extras)`, and it is
  NOT in `protected-broadcasts` — so KOReader may register a receiver. Untested link:
  whether a warmth-only write emits it, and whether the extra carries the current mode.
  Design it enables: write saved warmth at init; assert manual and re-write ONLY if the
  broadcast reports -1 — never touching modes 0/1/2.
- Device restored: warmth 10, `ctm_mode=0`, `color_temperature=100`,
  KOReader `frontlight_warmth=100`, `stay_on_while_plugged_in` back to 0, book returned
  to page 394/1089. One residue: `pre_ctm_mode=1` (was 0) from the AUTO test — inert.
