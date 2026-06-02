"""Test: service.sh resets sys.mode.slideUnlock to false within 2 seconds."""

import logging
import time

from . import adb
from .framework import BaseTest

log = logging.getLogger(__name__)

PROP = "sys.mode.slideUnlock"
SETTLE_S = 2.5  # service.sh polls every 1s; allow two cycles + margin


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

        log.info("waiting %.1fs for service.sh to reset it", SETTLE_S)
        time.sleep(SETTLE_S)

        after = adb.shell(f"getprop {PROP}")
        if after == "false":
            return True, "prop was reset to false by service.sh"
        return False, f"prop still {after!r} after {SETTLE_S}s"

    def teardown(self) -> None:
        adb.shell(f"setprop {PROP} false")
