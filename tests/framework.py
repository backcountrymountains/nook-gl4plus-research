"""Test framework for Nook GL4+ device tests."""

import logging
import time
from dataclasses import dataclass
from typing import Optional

log = logging.getLogger(__name__)


@dataclass
class DeviceSnapshot:
    """Records device settings before a test and restores them afterwards.

    Covers the settings most likely to be disturbed by any test:
      - screen brightness (0-100, Nook scale)
      - WiFi state
      - sys.mode.slideUnlock property

    Warmth is intentionally excluded — restoring it requires routing through
    GlowLightService, which is test_warmth's own responsibility.
    The sleep cover file is also excluded; test_sleep_cover handles that.
    """

    brightness: Optional[int] = None
    wifi_on: Optional[bool] = None
    slide_unlock: Optional[str] = None

    @staticmethod
    def capture() -> "DeviceSnapshot":
        from . import adb
        snap = DeviceSnapshot()

        raw = adb.shell("settings get system screen_brightness")
        try:
            snap.brightness = int(raw)
        except ValueError:
            pass

        wifi_raw = adb.shell("settings get global wifi_on")
        if wifi_raw == "1":
            snap.wifi_on = True
        elif wifi_raw == "0":
            snap.wifi_on = False

        prop = adb.shell("getprop sys.mode.slideUnlock")
        if prop:
            snap.slide_unlock = prop

        log.debug(
            "snapshot: brightness=%s wifi=%s slideUnlock=%s",
            snap.brightness, snap.wifi_on, snap.slide_unlock,
        )
        return snap

    def restore(self) -> None:
        from . import adb
        if self.brightness is not None:
            adb.shell(f"settings put system screen_brightness {self.brightness}")
        if self.wifi_on is not None:
            cmd = "enable" if self.wifi_on else "disable"
            adb.shell(f"svc wifi {cmd}", timeout=10)
        if self.slide_unlock is not None:
            adb.shell(f"setprop sys.mode.slideUnlock {self.slide_unlock}")
        log.debug(
            "snapshot restored: brightness=%s wifi=%s slideUnlock=%s",
            self.brightness, self.wifi_on, self.slide_unlock,
        )


@dataclass
class TestResult:
    name: str
    passed: bool
    message: str = ""
    duration_s: float = 0.0

    def __str__(self) -> str:
        status = "PASS" if self.passed else "FAIL"
        suffix = f" — {self.message}" if self.message else ""
        return f"[{status}] {self.name} ({self.duration_s:.1f}s){suffix}"


class BaseTest:
    """Base class for all device tests.

    Subclasses must set `name` and implement `run()`.
    `setup()` and `teardown()` are optional; teardown always runs.
    """

    name: str = "unnamed"

    def setup(self) -> None:
        pass

    def run(self) -> tuple[bool, str]:
        raise NotImplementedError

    def teardown(self) -> None:
        pass

    def execute(self) -> TestResult:
        log.info("--- starting: %s ---", self.name)
        t_start = time.monotonic()

        snapshot = DeviceSnapshot.capture()

        try:
            self.setup()
        except Exception as exc:
            snapshot.restore()
            duration = time.monotonic() - t_start
            return TestResult(self.name, False, f"setup failed: {exc}", duration)

        passed, message = False, "run() did not complete"
        try:
            passed, message = self.run()
        except Exception as exc:
            passed, message = False, f"exception: {exc}"
        finally:
            try:
                self.teardown()
            except Exception as exc:
                log.warning("teardown error in %s: %s", self.name, exc)
            snapshot.restore()

        duration = time.monotonic() - t_start
        result = TestResult(self.name, passed, message, duration)
        log.info("%s", result)
        return result


def run_suite(tests: list[BaseTest]) -> list[TestResult]:
    """Run a list of tests and return results."""
    results: list[TestResult] = []
    for test in tests:
        results.append(test.execute())
    return results


def print_summary(results: list[TestResult]) -> None:
    total = len(results)
    passed = sum(1 for r in results if r.passed)
    failed = total - passed

    print()
    print("=" * 60)
    print(f"Results: {passed}/{total} passed", end="")
    if failed:
        print(f"  ({failed} failed)")
    else:
        print()
    print("=" * 60)
    for result in results:
        print(f"  {result}")
    print()
