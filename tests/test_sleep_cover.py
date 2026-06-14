"""Test: cover_watcher.sh copies updated sleep cover to all Art slots in /system/media/SleepImageNook/.

Pipeline under test:
  1. cover_watcher.sh monitors logcat for POWERHINT "screen on" events.
  2. On wakeup, it compares the cover's mtime to its last-known value.
  3. If changed, it calls cover_handler.sh which remounts /system rw, copies
     the cover to all 11 Art slots, then remounts ro.

The test simulates this by:
  - Pushing a small distinctive PNG to change the cover mtime.
  - Doing a screen off/on cycle to fire the POWERHINT "screen on" event.
  - Waiting for cover_handler.sh to finish, then checking Art file sizes.

Teardown restores the real cover via the same pipeline so it is left in a
consistent state for subsequent runs.
"""

import logging
import os
import struct
import tempfile
import time
import zlib

from . import adb
from .framework import BaseTest

log = logging.getLogger(__name__)

COVER_SRC = "/sdcard/koreader/sleep_cover.png"
SLEEP_DIR = "/system/media/SleepImageNook"
ART_FILES = ["Art1_bk.png", "Art3_wt.png", "Art6_wt.png"]

# Timing constants
SCREEN_OFF_S = 2.0   # seconds for the device to fully sleep after power keyevent
HANDLER_S = 6.0      # seconds for cover_handler.sh to remount + copy 11 files + remount


def _make_solid_png(width: int, height: int, r: int, g: int, b: int) -> bytes:
    """Create a minimal valid RGB PNG of the given dimensions and solid colour."""

    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    signature = b"\x89PNG\r\n\x1a\n"
    ihdr_data = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    ihdr = chunk(b"IHDR", ihdr_data)

    row = b"\x00" + bytes([r, g, b]) * width
    raw = row * height
    idat = chunk(b"IDAT", zlib.compress(raw))
    iend = chunk(b"IEND", b"")
    return signature + ihdr + idat + iend


class SleepCoverPropagationTest(BaseTest):
    name = "sleep cover propagation"

    _tmp_path: str = ""
    _real_cover_path: str = ""
    _png_size: int = 0

    def setup(self) -> None:
        # Pull the real cover so teardown can restore it exactly.
        fd, self._real_cover_path = tempfile.mkstemp(suffix=".png", prefix="nook_real_cover_")
        os.close(fd)
        log.info("pulling real cover from device for later restore")
        adb.pull(COVER_SRC, self._real_cover_path)

        # Create a distinctive test PNG (10x10 orange, ~75 bytes).
        png_data = _make_solid_png(10, 10, 255, 128, 0)
        self._png_size = len(png_data)
        log.info("test PNG size: %d bytes", self._png_size)

        fd, self._tmp_path = tempfile.mkstemp(suffix=".png", prefix="nook_test_")
        with os.fdopen(fd, "wb") as f:
            f.write(png_data)

    def run(self) -> tuple[bool, str]:
        before = adb.shell_root(f"stat -c %s {SLEEP_DIR}/{ART_FILES[0]}")
        log.info("Art1_bk.png size before push: %s bytes", before)

        # Push test PNG — this changes the cover's mtime, arming the watcher.
        log.info("pushing test cover (%d bytes) to %s", self._png_size, COVER_SRC)
        adb.push(self._tmp_path, COVER_SRC)

        # Screen off → on cycle fires POWERHINT "screen on", which triggers
        # cover_watcher.sh to detect the mtime change and run cover_handler.sh.
        log.info("sleeping device (power keyevent)...")
        adb.shell("input keyevent 26")
        time.sleep(SCREEN_OFF_S)

        log.info("waking device (power keyevent) — watcher will copy on 'screen on'")
        adb.shell("input keyevent 26")
        time.sleep(HANDLER_S)

        failures: list[str] = []
        for art in ART_FILES:
            size_str = adb.shell_root(f"stat -c %s {SLEEP_DIR}/{art}")
            try:
                size = int(size_str)
            except ValueError:
                failures.append(f"{art}: could not read size (got {size_str!r})")
                continue
            if size != self._png_size:
                failures.append(f"{art}: size {size} != expected {self._png_size}")
            else:
                log.info("%s: size matches (%d bytes)", art, size)

        if failures:
            return False, "; ".join(failures)
        return True, f"all {len(ART_FILES)} sampled Art files updated ({self._png_size} bytes)"

    def teardown(self) -> None:
        if self._tmp_path and os.path.exists(self._tmp_path):
            os.unlink(self._tmp_path)
        # Push the real cover back; do a screen cycle to let the watcher restore Art files.
        if self._real_cover_path and os.path.exists(self._real_cover_path):
            log.info("restoring real cover via watcher pipeline")
            adb.push(self._real_cover_path, COVER_SRC)
            os.unlink(self._real_cover_path)
            self._real_cover_path = ""
            adb.shell("input keyevent 26")
            time.sleep(SCREEN_OFF_S)
            adb.shell("input keyevent 26")
            time.sleep(HANDLER_S)
