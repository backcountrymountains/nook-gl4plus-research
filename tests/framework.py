"""Test framework for Nook GL4+ device tests."""

import logging
import time
from dataclasses import dataclass, field
from typing import Optional

log = logging.getLogger(__name__)


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

        try:
            self.setup()
        except Exception as exc:
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
