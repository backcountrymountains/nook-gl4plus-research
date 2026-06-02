"""Test: GlowLightService accepts warmth intents and updates the hardware register.

Sends action_set_color_temperature directly to com.nook.partner GlowLightService
and verifies that Settings.System.screen_brightness_color reflects the new value.
Uses two different warmth values and confirms the setting follows each command.
"""

import logging
import time

from . import adb
from .framework import BaseTest

log = logging.getLogger(__name__)

GLOWLIGHT_COMPONENT = "com.nook.partner/.service.GlowLightService"
ACTION = "action_set_color_temperature"
EXTRA = "extra_color_temperature"
SETTINGS_KEY = "screen_brightness_color"

# KOReader warmth scale is 0-10; the intent uses warmth * 10 (0-100).
# Pick two values that are clearly distinct.
TEST_VALUES: list[tuple[int, int]] = [
    (3, 30),   # warmth=3  → intent value 30
    (8, 80),   # warmth=8  → intent value 80
]
SETTLE_S = 1.5


def _send_warmth(intent_value: int) -> str:
    cmd = (
        f"am startservice -n {GLOWLIGHT_COMPONENT} "
        f"-a {ACTION} --ei {EXTRA} {intent_value}"
    )
    return adb.shell(cmd)


def _read_warmth() -> int | None:
    raw = adb.shell(f"settings get system {SETTINGS_KEY}")
    try:
        return int(raw)
    except ValueError:
        return None


class WarmthControlTest(BaseTest):
    name = "warmth control via GlowLightService"

    _original_warmth: int | None = None

    def setup(self) -> None:
        self._original_warmth = _read_warmth()
        log.info("original %s = %s", SETTINGS_KEY, self._original_warmth)

    def run(self) -> tuple[bool, str]:
        for warmth, intent_value in TEST_VALUES:
            log.info("sending warmth=%d (intent value %d)", warmth, intent_value)
            result = _send_warmth(intent_value)
            log.debug("startservice result: %s", result)

            time.sleep(SETTLE_S)

            actual = _read_warmth()
            log.info("%s after command: %s", SETTINGS_KEY, actual)

            if actual is None:
                return False, f"could not read {SETTINGS_KEY} after warmth={warmth}"
            if actual != warmth:
                return (
                    False,
                    f"warmth={warmth} sent, expected {SETTINGS_KEY}={warmth}, got {actual}",
                )

        return True, f"both warmth values ({[w for w, _ in TEST_VALUES]}) applied correctly"

    def teardown(self) -> None:
        if self._original_warmth is not None:
            restore_intent = self._original_warmth * 10
            log.info("restoring warmth to %d (intent %d)", self._original_warmth, restore_intent)
            _send_warmth(restore_intent)
