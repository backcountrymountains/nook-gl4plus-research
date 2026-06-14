"""ADB helper for Nook GL4+ device tests.

All commands target the remote ADB server at 192.168.1.92:5037.
"""

import logging
import subprocess
from typing import Optional

log = logging.getLogger(__name__)

ADB_HOST = "192.168.1.92"
ADB_PORT = 5037
_BASE: list[str] = ["adb", "-H", ADB_HOST, "-P", str(ADB_PORT)]


class AdbError(Exception):
    pass


def _run(args: list[str], timeout: int) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise AdbError(f"ADB command timed out after {timeout}s: {args}") from exc


def shell(cmd: str, timeout: int = 15) -> str:
    """Run a shell command on the device, return stdout stripped."""
    result = _run([*_BASE, "shell", cmd], timeout=timeout)
    return result.stdout.strip()


def shell_root(cmd: str, timeout: int = 15) -> str:
    """Run a shell command via su, return stdout stripped."""
    return shell(f"su -c '{cmd}'", timeout=timeout)


def push(local_path: str, remote_path: str, timeout: int = 30) -> None:
    """Push a local file to the device. Raises AdbError on failure."""
    result = _run([*_BASE, "push", local_path, remote_path], timeout=timeout)
    if result.returncode != 0:
        raise AdbError(f"push failed: {result.stderr.strip()}")
    log.debug("pushed %s -> %s", local_path, remote_path)


def pull(remote_path: str, local_path: str, timeout: int = 30) -> None:
    """Pull a file from the device to a local path. Raises AdbError on failure."""
    result = _run([*_BASE, "pull", remote_path, local_path], timeout=timeout)
    if result.returncode != 0:
        raise AdbError(f"pull failed: {result.stderr.strip()}")
    log.debug("pulled %s -> %s", remote_path, local_path)


def logcat_since(timestamp: str, timeout: int = 10) -> str:
    """Return logcat lines since a given timestamp (MM-DD HH:MM:SS.mmm)."""
    result = _run(
        [*_BASE, "logcat", "-d", "-t", timestamp],
        timeout=timeout,
    )
    return result.stdout


def check_connection(timeout: int = 5) -> bool:
    """Return True if the device is reachable."""
    try:
        out = shell("echo ok", timeout=timeout)
        return out == "ok"
    except AdbError:
        return False
