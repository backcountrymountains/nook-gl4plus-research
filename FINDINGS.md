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
