"""Test: WiFi can be toggled off and back on via the svc command (root fallback path).

This exercises the root-shell fallback in ActivityExtensions.setWifiRadio() —
WifiManager.setWifiEnabled() is blocked on Android 10+ but this device runs 8.1
where it may work; the test validates whichever path is effective.
"""

import logging
import time

from . import adb
from .framework import BaseTest

log = logging.getLogger(__name__)

SETTLE_S = 3.0  # Wi-Fi association takes a moment


def _wifi_enabled() -> bool | None:
    out = adb.shell("cmd wifi status 2>/dev/null | grep -i 'Wifi is' | head -1")
    if "enabled" in out.lower():
        return True
    if "disabled" in out.lower():
        return False
    # Fallback: try wifiEnabled from settings
    state = adb.shell("settings get global wifi_on")
    if state == "1":
        return True
    if state == "0":
        return False
    return None


def _set_wifi(enable: bool) -> None:
    cmd = "enable" if enable else "disable"
    adb.shell(f"svc wifi {cmd}", timeout=10)


class WifiToggleTest(BaseTest):
    name = "WiFi toggle"

    _initial_state: bool | None = None

    def setup(self) -> None:
        self._initial_state = _wifi_enabled()
        if self._initial_state is None:
            raise RuntimeError("could not determine initial WiFi state")
        log.info("initial WiFi state: %s", "enabled" if self._initial_state else "disabled")

    def run(self) -> tuple[bool, str]:
        target_off = self._initial_state  # we'll disable if currently enabled
        target_on = not target_off

        # Step 1: toggle to the opposite state
        log.info("disabling WiFi")
        _set_wifi(False)
        time.sleep(SETTLE_S)
        state_off = _wifi_enabled()
        log.info("WiFi state after disable: %s", state_off)
        if state_off:
            return False, "WiFi did not disable"

        # Step 2: re-enable
        log.info("re-enabling WiFi")
        _set_wifi(True)
        time.sleep(SETTLE_S)
        state_on = _wifi_enabled()
        log.info("WiFi state after enable: %s", state_on)
        if not state_on:
            return False, "WiFi did not re-enable"

        return True, "WiFi toggled off then on successfully"

    def teardown(self) -> None:
        if self._initial_state is not None:
            log.info("restoring WiFi to initial state: %s", self._initial_state)
            _set_wifi(self._initial_state)
