# Nook GL4+ EPD Mode Testing Guide

## Background

`getMode()` in `NookEmperorEPDController.kt` controls which refresh paths invoke the EPD
controller. The logic lives in `base/ffi/framebuffer_android.lua`:

- `refreshFullImp` → always calls EPD (both `"full-only"` and `"all"`)
- `refreshPartialImp` → only calls EPD if `getMode() == "all"`
- `refreshUIImp` → only calls EPD if `getMode() == "all"`
- `refreshFastImp` → only calls EPD if `getMode() == "all"`

With `"full-only"`, the EPD controller is only invoked on full-flash page turns.
All other screen updates (menus, partial page turns) write pixels to the ANativeWindow
with no EPD waveform command.

## Observable Signatures

| Action | Stock KOReader (no GL4+ driver) | Our build: `"full-only"` | Our build: `"all"` |
|---|---|---|---|
| Page turn at "Every page" refresh | No white flash | **White flash** before clean page | White flash (same) |
| Page turn at "Never" full refresh | No flash, possible ghost | No flash (no EPD call) | Fast GU16 update, possible ghost |
| Tap center to open menu | No flash | No flash (no EPD call) | GU16 EPD refresh |
| Tap outside to close menu | No flash | No flash | GU16 EPD refresh |

The white flash on page turns is the most reliable indicator that the EPD controller
GC16 path is working. GU16 (partial) is faster but may leave faint ghosting at pixel edges.

## Setup

Open any text book in KOReader. The "Full refresh rate" setting is at:
**tap-center menu → ☰ → Settings → Eink settings → Full refresh rate**

## Test 1: Does GC16 full refresh work? (most important)

1. Set "Full refresh rate" → **Every page**
2. Turn pages by tapping the right edge repeatedly
3. **Pass**: brief white flash (~0.3–0.5 sec) before each page draws cleanly
4. **Fail**: pages appear without any flash (EPD controller not firing)

This confirms `view.invalidate(EMPEROR_EINK_NO_MERGE | GC16_MODE)` is working.

## Test 2: Partial refresh behavior (distinguishes `"full-only"` vs `"all"`)

1. Set "Full refresh rate" → **Never**
2. Turn pages
3. With **`"full-only"`**: pages appear instantly, no flash, no EPD call at all (possible ghost)
4. With **`"all"`**: ~100–200ms GU16 update, faster than GC16, may show slight grey smearing

If Test 2 with `"all"` looks clean (no frozen frames, no corruption), it's safe to
change `getMode()` to `"all"`.

## Test 3: Menu rendering (only meaningful with `"all"`)

1. While reading, tap center to open the reading menu
2. Tap outside to close it
3. With **`"full-only"`**: menu appears/disappears without EPD refresh (just pixel write)
4. With **`"all"`**: menu triggers GU16 EPD call on each show/hide

## Comparing Against Stock KOReader

Stock KOReader has no EPD controller for bnrv1300 — it falls through to `platform = "none"`,
so `has_eink_screen = false` and `has_eink_full_support = false`. Zero EPD calls are made
for any action.

Since both builds use the same package name (`org.koreader.launcher`), you can't install
them side by side. Procedure:

1. Install **stock nightly** (koreader.github.io/koreader) → run Tests 1–3
   - Expected: zero white flashes on anything
2. Reinstall **our build** → run Tests 1–3
   - Expected: white flash on page turns (Test 1) confirms our driver is active

## Switching from `"full-only"` to `"all"` for testing

Edit `NookEmperorEPDController.kt` line 29:
```kotlin
// Before:
override fun getMode(): String = "full-only"

// After:
override fun getMode(): String = "all"
```

Rebuild and install, then run Tests 1–3. If Test 2 and Test 3 look correct, keep `"all"`.
If partial refreshes show corruption or frozen frames, revert to `"full-only"`.

## What to report back to hugleo

- Test 1 result: does the white flash appear on full page turns?
- Test 2 result with `"all"`: do partial refreshes render correctly or glitch?
- Whether `getMode()` should be `"full-only"` or `"all"` based on the above
