"""Test: cover_watcher.sh resets sys.mode.slideUnlock to false on screen wakeup.

slideUnlock suppression is now event-driven: POWERHINT "screen on" fires during
the wake-up sequence and cover_watcher.sh resets the prop before SystemUI renders
the lock screen.  The test simulates this by setting the prop to true, doing a
screen off/on cycle to fire the event, then verifying the prop is false.
"""

import logging
import time

from . import adb
from .framework import BaseTest

log = logging.getLogger(__name__)

PROP = "sys.mode.slideUnlock"
SCREEN_OFF_S = 2.0   # seconds for device to fully sleep
SETTLE_S = 1.5       # seconds after wake keyevent for handler to run


class SlideUnlockSuppressionTest(BaseTest):
    name = "slideUnlock suppression"

    def setup(self) -> None:
        adb.shell(f"setprop {PROP} false")

    def run(self) -> tuple[bool, str]:
        log.info("setting %s = true", PROP)
        adb.shell(f"setprop {PROP} true")

        before = adb.shell(f"getprop {PROP}")
        if before != "true":
            return False, f"setprop did not take effect (got: {before!r})"

        # Sleep the device, then wake it — POWERHINT "screen on" fires and
        # cover_watcher.sh resets the prop before SystemUI reads it.
        log.info("sleeping device to trigger wake-up event...")
        adb.shell("input keyevent 26")
        time.sleep(SCREEN_OFF_S)

        log.info("waking device — cover_watcher.sh will reset prop on 'screen on'")
        adb.shell("input keyevent 26")
        time.sleep(SETTLE_S)

        after = adb.shell(f"getprop {PROP}")
        if after == "false":
            return True, "prop was reset to false by cover_watcher.sh on screen-on event"
        return False, f"prop still {after!r} after screen wake cycle"

    def teardown(self) -> None:
        adb.shell(f"setprop {PROP} false")
