"""Test: service.sh copies updated sleep cover to all Art slots in /system/media/SleepImageNook/.

Pushes a small but valid PNG to /sdcard/koreader/sleep_cover.png and verifies
that service.sh detects the mtime change and copies it to the Art files.
The test PNG has a distinctive file size so we can confirm the copy happened.
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
# Verify at least one representative Art file
ART_FILES = ["Art1_bk.png", "Art3_wt.png", "Art6_wt.png"]
SETTLE_S = 2.5  # inotifyd fires immediately on close-write; allow 2.5s for copy


def _make_solid_png(width: int, height: int, r: int, g: int, b: int) -> bytes:
    """Create a minimal valid RGB PNG of the given dimensions and solid colour."""

    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    signature = b"\x89PNG\r\n\x1a\n"
    ihdr_data = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    ihdr = chunk(b"IHDR", ihdr_data)

    # Each row: filter byte (0=None) + RGB pixels
    row = b"\x00" + bytes([r, g, b]) * width
    raw = row * height
    idat = chunk(b"IDAT", zlib.compress(raw))
    iend = chunk(b"IEND", b"")
    return signature + ihdr + idat + iend


class SleepCoverPropagationTest(BaseTest):
    name = "sleep cover propagation"

    _tmp_path: str = ""
    _png_size: int = 0

    def setup(self) -> None:
        # Create a distinctive test PNG (10x10 orange)
        png_data = _make_solid_png(10, 10, 255, 128, 0)
        self._png_size = len(png_data)
        log.info("test PNG size: %d bytes", self._png_size)

        fd, self._tmp_path = tempfile.mkstemp(suffix=".png", prefix="nook_test_")
        with os.fdopen(fd, "wb") as f:
            f.write(png_data)

    def run(self) -> tuple[bool, str]:
        # Record Art file size before push (to detect the change)
        before = adb.shell_root(f"stat -c %s {SLEEP_DIR}/{ART_FILES[0]}")
        log.info("Art1_bk.png size before: %s bytes", before)

        # inotifyd fires on close-write — the push itself triggers the copy.
        log.info("pushing test cover PNG (%d bytes) to %s", self._png_size, COVER_SRC)
        adb.push(self._tmp_path, COVER_SRC)

        log.info("waiting %.1fs for service.sh to detect mtime change and copy", SETTLE_S)
        time.sleep(SETTLE_S)

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
