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
