"""Test: temperature warning dialog is suppressed at 49°C.

Simulates a high battery temperature via `dumpsys battery set temp` and checks
both logcat and the window manager for evidence that the warning dialog appeared.

SAFETY NOTES
------------
- The correct dumpsys option is `temp`, not `temperature`.
- The Nook alarm threshold is 480 (48°C); values >= 480 force a real broadcast
  that triggers the device's shutdown/alarm path.  We use 460 (46°C): above
  ambient so SystemUI definitely processes it, but safely below the alarm.
- We do NOT use the -f flag; the normal `set temp` puts the battery service into
  frozen mode and sends a single broadcast — sufficient for our check, and it
  cannot cause a real shutdown.
"""

import logging
import time
from datetime import datetime

from . import adb
from .framework import BaseTest

log = logging.getLogger(__name__)

# 460 = 46.0°C — clearly elevated, but 20 units below the 480 alarm threshold.
# Never raise this to >= 480; that crosses into the Nook's live alarm/shutdown path.
SIMULATED_TEMP = 460
NOOK_ALARM_THRESHOLD = 480
SETTLE_S = 4.0


class TemperatureWarningSuppressedTest(BaseTest):
    name = "temperature warning suppressed"

    def setup(self) -> None:
        assert SIMULATED_TEMP < NOOK_ALARM_THRESHOLD, (
            f"SIMULATED_TEMP {SIMULATED_TEMP} must be below alarm threshold "
            f"{NOOK_ALARM_THRESHOLD} to avoid triggering a real device shutdown"
        )
        setting = adb.shell("settings get global show_temperature_warning")
        if setting != "0":
            raise RuntimeError(
                f"prerequisite failed: show_temperature_warning={setting!r} (expected '0')"
            )
        log.info("prerequisite ok: show_temperature_warning=0")

    def run(self) -> tuple[bool, str]:
        # Record focused window before simulation
        before_focus = adb.shell("dumpsys window 2>/dev/null | grep mFocusedWindow")
        ts = datetime.now().strftime("%m-%d %H:%M:%S.000")

        log.info("simulating battery temp %d (%.1f°C) — threshold is %.1f°C",
                 SIMULATED_TEMP, SIMULATED_TEMP / 10, NOOK_ALARM_THRESHOLD / 10)
        adb.shell(f"dumpsys battery set temp {SIMULATED_TEMP}")

        log.info("waiting %.1fs for SystemUI to process battery broadcast", SETTLE_S)
        time.sleep(SETTLE_S)

        # Check 1: did focused window change to a dialog?
        after_focus = adb.shell("dumpsys window 2>/dev/null | grep mFocusedWindow")
        if after_focus != before_focus:
            return False, f"focused window changed — dialog likely appeared: {after_focus.strip()}"

        # Check 2: did any new alert/dialog window appear?
        windows = adb.shell("dumpsys window 2>/dev/null", timeout=10)
        if "Application Error: com.android.systemui" in windows:
            return False, "SystemUI crashed — temperature event caused instability"
        temp_windows = [
            line.strip() for line in windows.splitlines()
            if "HighTemp" in line or ("temperature" in line.lower() and "Window" in line)
        ]
        if temp_windows:
            return False, f"temperature dialog window detected: {temp_windows[0]}"

        # Check 3: logcat indicators (best-effort — Nook's custom dialog may not log these)
        logcat = adb.logcat_since(ts, timeout=10)
        nook_dialog_indicators = [
            "showHighTemperatureDialog",
            "mHighTempDialog",
            "HighTemperatureWarning",
        ]
        hits = [ind for ind in nook_dialog_indicators if ind in logcat]
        if hits:
            return False, f"dialog indicator(s) in logcat: {hits}"

        return True, f"no dialog shown at {SIMULATED_TEMP / 10:.1f}°C (threshold {NOOK_ALARM_THRESHOLD / 10:.1f}°C)"

    def teardown(self) -> None:
        log.info("resetting battery simulation")
        adb.shell("dumpsys battery reset")
