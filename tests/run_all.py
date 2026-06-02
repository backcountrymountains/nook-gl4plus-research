"""Entry point: discover and run all Nook GL4+ device tests.

Usage (from repo root):
    python3 -m tests.run_all
    python3 -m tests.run_all slideunlock temperature   # run specific tests by name fragment
"""

import logging
import sys

from . import adb
from .framework import BaseTest, run_suite, print_summary
from .test_slideunlock import SlideUnlockSuppressionTest
from .test_temperature import TemperatureWarningSuppressedTest
from .test_sleep_cover import SleepCoverPropagationTest
from .test_warmth import WarmthControlTest
from .test_wifi import WifiToggleTest

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(name)s - %(message)s",
    stream=sys.stdout,
    force=True,
)

log = logging.getLogger(__name__)

ALL_TESTS: list[BaseTest] = [
    SlideUnlockSuppressionTest(),
    TemperatureWarningSuppressedTest(),
    SleepCoverPropagationTest(),
    WarmthControlTest(),
    WifiToggleTest(),
]


def main() -> None:
    log.info("connecting to device at %s:%d", adb.ADB_HOST, adb.ADB_PORT)
    if not adb.check_connection(timeout=5):
        log.error("device not reachable — is adb running at %s:%d?", adb.ADB_HOST, adb.ADB_PORT)
        sys.exit(1)
    log.info("device connected")

    # Filter by name fragment if arguments were given
    filters = [arg.lower() for arg in sys.argv[1:]]
    tests = ALL_TESTS
    if filters:
        tests = [t for t in ALL_TESTS if any(f in t.name.lower() for f in filters)]
        if not tests:
            log.error("no tests matched filters: %s", filters)
            sys.exit(1)
        log.info("running %d/%d tests matching: %s", len(tests), len(ALL_TESTS), filters)

    results = run_suite(tests)
    print_summary(results)

    if any(not r.passed for r in results):
        sys.exit(1)


if __name__ == "__main__":
    main()
