# STATE — session cursor

Last updated: 2026-09-04. Topic: the Nook GL4 Plus **warmth-resets-to-cold-on-unlock** bug.

Settled facts live in `FINDINGS.md` — read it first, it now has every receipt from this
session. This file is only what is *in flight*.

---

## Where the work stands

**Both PRs are submitted and awaiting review.** The investigation is finished: root cause
settled, reproduced from a real reboot, fix verified on hardware, upstream confirmed empty
of any competing work. There is no open question blocking the PRs.

| | |
|---|---|
| `koreader/android-luajit-launcher#620` | Kotlin: assert `CTM_MODE_MANUAL` before the first warmth write. 1 file, +39/-1. |
| `koreader/koreader#16004` | Lua: push saved warmth to hardware in `AndroidPowerD:init()`. 1 file, +19/-0. |

They are cross-linked and depend on each other: #620 makes a warmth write *persist*, #16004
makes a warmth write *happen at startup*. Either alone is a partial fix.

## The branches

Both cut fresh off upstream `origin/master`, pushed to `fork`
(`backcountrymountains`). Local branches still exist; the worktrees used to build them were
removed.

- launcher — `nook-gl4plus-ctm-warmth`, commit **`e152101`**, based on upstream `0bb27ff`.
  File content is **byte-identical** to `81c797b`, the version verified on hardware.
- koreader — `android-restore-warmth-at-startup`, commit **`73edee335`**.

## How the fix was verified (2026-09-04, on device)

Not by an APK rebuild — by writing the **real** patched files to the device. See
`FINDINGS.md` § "Can KOReader's Lua be patched on-device without rebuilding".

Broken device (`ctm_mode` key absent → warmth forced 0 on every wake) → launch KOReader →
warmth restored 0→10 with **no slider touch**, no Lua error, and it held across a screen
cycle with `ctm_mode=0` persisted:

```
Lights  : Setting warmth to 10 of 10
Lights  : CTM mode set to manual
CTMService: setupCTM:0
LightsService: kk-1-brightness(color):10
```

## Exact next step

**A reviewer has responded — see `## Log` at the bottom.** The comment-verbosity round is
answered and pushed; both PRs are back to awaiting review. The list below still governs
whatever comes next:

1. **If asked to change the Kotlin** (most likely: `@Volatile ctmModeAsserted` →
   `AtomicBoolean.compareAndSet`, which I raised myself in the PR notes) — that change is
   **unverified**, because it needs an APK rebuild to test. Build with the recipe below and
   re-run the break→launch check before pushing.
2. **If asked to prove the Lua change on non-Nook hardware** — say plainly that it was only
   tested on a BNRV1300; the PR body already discloses this.
3. Consider filing an upstream issue. There still is **none** describing this bug; the two
   PR bodies carry the whole diagnosis, which may be enough.

## Deliberately not done — and why

- **No APK rebuilt from the upstream base.** The launcher PR is a cherry-pick whose file
  content is byte-identical to the hardware-verified `81c797b`, so the verification chain
  holds. A rebuild is only needed if the Kotlin changes.
- **`@Volatile` kept instead of `AtomicBoolean`.** Changing it would mean submitting Kotlin
  that had not been run. Raised in the PR instead.
- **Test #5 — `com.nook.partner` disabled → `startService` returns null — never run.** That
  package must stay ENABLED, so it is a misconfiguration rather than a supported state; the
  existing defensive branch logs and does not latch. Low value.
- **Test #3 — deep-sleep wake — only partial.** The device does suspend hard
  (`PowerManagerEx`) and warmth held across those cycles, but `power_enhance_enable` reads
  `null` on this build, so that named knob was never exercised.

## Ruled out — do not re-derive

All of these now have full entries with receipts in `FINDINGS.md`; the one-line versions:

- Flipping `hasStandaloneWarmth()` gives self-heal — **NO**, fires only on a manual
  frontlight toggle.
- Clobbering CTM AUTO/SCHEDULE needs a restore path — **NO**, only mode `-1` is broken;
  0/1/2 all behave the same for KOReader.
- Anyone else is fixing this upstream — **NO**, and `#14574` is our own FR, not a bug report.
- `com.example.ctm` / "Display Settings" repairs the mode — **NO**.
- `screen_brightness_color_backup` is the restored value — **NO**.
- `com.nook.partner` can be disabled — **NO**, it hosts `GlowLightService`. What KOReader
  users disable is `bn.ereader` + `com.bn.nook.hub`, and `am force-stop` on nookPartner is a
  no-op (PERSISTENT — `kill -9` the pid).

## Landmines in the build/repo — still real, still unfixed

- **`koreader` master does not build a working APK.** Its submodule pointer `da919d8` has no
  `isWifiEnabled`, which `frontend/device/android/device.lua` calls → instant crash at
  startup. Build against `nook-personal` (`a22c7a7`), a superset. Note the upstream launcher
  master likewise lacks `isWifiEnabled`, so it cannot be combined with our local koreader
  master either.
- **`koreader-nook-gl4plus/README.md` build section is wrong twice**: says
  `ANDROID_ARCH=arm64` (device is `armeabi-v7a`) and omits that the output APK is unsigned.
  Partially addressed in `0f4042a`; re-check before pointing users at it.
- Working build recipe (all four gotchas):
  ```bash
  docker run --rm -u 0:0 -v /home/point/nook/koreader:/src -w /src \
    -e BASH_ENV=/home/ko/.bashrc -e HOME=/home/ko koreader/koandroid:0.9.1-22.04 \
    bash -c "git config --global --add safe.directory '*'; \
             make TARGET=android ANDROID_ARCH=arm ANDROID_VERSION=1278442 \
                  OUTPUT_DIR=build INSTALL_DIR=install update; \
             rc=\$?; chown -R 1000:1000 /src; exit \$rc"
  # then zipalign + apksigner with ~/.android/debug.keystore (alias androiddebugkey, pass android)
  ```
  container `ko` is uid 1001 vs host 1000 → run as root and `chown` back · git refuses the
  repo as root unless `safe.directory '*'` is in a **config file** (`GIT_CONFIG_*` is ignored
  for this key), else `versCode` is empty and gradle dies on `For input string: ""` ·
  `ANDROID_VERSION` must exceed the installed versionCode (**1278441**) or install fails
  with `INSTALL_FAILED_VERSION_DOWNGRADE`.

## Repo state

- `nook-gl4plus-research` (this repo, on `master`): committed and pushed. Untracked and
  intentionally left: `logs/`, `nook-workspace.code-workspace`.
- `koreader`: on `master` with 8 local commits not upstream and 219 behind. Working tree
  clean except the **deliberately dirty submodule pointers** (`base`,
  `platform/android/luajit-launcher` — the latter sits on `nook-gl4plus-ctmfix`), plus
  untracked `build/` and `ko-ctmfix*-signed.apk`. A stale `.git/index.lock` from the
  2026-08-13 hard stop was cleared this session.
- `koreader-nook-gl4plus`: clean at `0f4042a`.

## Device state

Working and restored to how the session found it. Warmth **10**, `ctm_mode=0`,
`color_temperature=100`, KOReader `frontlight_warmth=100`, book back at page **394/1089**,
`stay_on_while_plugged_in` back to **0**. Installed APK is `ko-ctmfix3-signed.apk`
(nook-personal + fix, versionCode **1278441**) — it does **not** contain the Lua half, so
the device does not self-heal yet; it is simply in a repaired state. All test artifacts were
removed: the device Lua is stock again and `/sdcard/koreader/patches/` holds only the
pre-existing `2111-nook-gl4plus-deepsleep.lua`.

## Log

- 08:2x Frenzie (MEMBER) reviewed BOTH PRs, same ask: comments too verbose. #620 issue
  comment "make its added comments shorter and simpler"; #16004 inline
  `discussion_r3939727712` on powerd.lua:50 "Probably just remove the comment."
- 08:3x Trimmed and pushed. koreader `262e32910` (+19/-0 → **+9/-0**), launcher `2cfaffe`
  (+39/-1 → **+29/-1**). Added as new commits on top, NOT amended — both repos squash-merge
  (receipt: `git log origin/master` is all single-parent `... (#NNNN)` subjects), so no
  force-push was needed.
- Changes are **comment-only** — verified no code line differs (`git diff -U0` filtered of
  comment lines is empty in both). The hardware-verification chain from 2026-09-04 therefore
  still holds and **no APK rebuild is needed**. No Lua interpreter on this box, but only
  whole-line comments were deleted.
- Kept one short comment in each: powerd.lua's `warmth_scale` line (it looks deletable
  without it) and the launcher's IntentService-ordering note. The full diagnosis was already
  in the commit messages and PR bodies, so the trim lost nothing.
- Worktrees `/tmp/wt-ko` `/tmp/wt-lj` used and removed; `koreader` master tree left exactly
  as found (submodule pointers still deliberately dirty, launcher on `nook-gl4plus-ctmfix`).
- Not done: no reply posted to either reviewer thread, and neither thread resolved.
