"""Test: temperature warning dialog is suppressed at 49°C.

Simulates a high battery temperature via `dumpsys battery set temperature` and
checks logcat for evidence that the dialog was shown.  If show_temperature_warning
is correctly set to 0 in Settings.Global, no dialog strings should appear.
"""

import logging
import time
from datetime import datetime

from . import adb
from .framework import BaseTest

log = logging.getLogger(__name__)

# 490 = 49.0°C — above the 48°C Nook alarm threshold, below 50°C shutdown
SIMULATED_TEMP = 490
SETTLE_S = 4.0

# Strings that appear in logcat when SystemUI shows the temperature warning
DIALOG_INDICATORS = [
    "showHighTemperatureDialog",
    "mHighTempDialog",
    "HighTemperatureWarning",
    "showHighTemperatureWarning",
    "high_temp_dialog",
]


class TemperatureWarningSuppressedTest(BaseTest):
    name = "temperature warning suppressed"

    def setup(self) -> None:
        setting = adb.shell("settings get global show_temperature_warning")
        if setting != "0":
            raise RuntimeError(
                f"prerequisite failed: show_temperature_warning={setting!r} (expected '0')"
            )
        log.info("prerequisite ok: show_temperature_warning=0")

    def run(self) -> tuple[bool, str]:
        ts = datetime.now().strftime("%m-%d %H:%M:%S.000")
        log.info("simulating battery temperature %d (%.1f°C)", SIMULATED_TEMP, SIMULATED_TEMP / 10)
        adb.shell(f"dumpsys battery set temperature {SIMULATED_TEMP}")

        log.info("waiting %.1fs for SystemUI to process ACTION_BATTERY_CHANGED", SETTLE_S)
        time.sleep(SETTLE_S)

        logcat = adb.logcat_since(ts, timeout=10)

        hits = [ind for ind in DIALOG_INDICATORS if ind in logcat]
        if hits:
            return False, f"dialog indicator(s) found in logcat: {hits}"

        # Also check for any new dialog window in window manager
        windows = adb.shell("dumpsys window windows", timeout=10)
        temp_windows = [
            line for line in windows.splitlines()
            if "HighTemp" in line or "temperature" in line.lower()
        ]
        if temp_windows:
            return False, f"temperature dialog window detected: {temp_windows[0]}"

        return True, f"no dialog shown at {SIMULATED_TEMP / 10:.1f}°C"

    def teardown(self) -> None:
        log.info("resetting battery simulation")
        adb.shell("dumpsys battery reset")
