#!/usr/bin/env python3
"""Build nook-gl4plus-sleep-cover-v1.zip from the module staging directory."""

import zipfile
from pathlib import Path

SRC = Path("/tmp/nook_sleep_cover_module")
OUT = Path("/home/point/nook-gl4plus-tweaks/files/sleep_cover/nook-gl4plus-sleep-cover-v1.zip")

with zipfile.ZipFile(OUT, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for path in sorted(SRC.rglob("*")):
        if path.is_file():
            arcname = path.relative_to(SRC)
            zf.write(path, arcname)
            print(f"  added: {arcname}")

print(f"\nWrote {OUT} ({OUT.stat().st_size} bytes)")

print("\nContents:")
with zipfile.ZipFile(OUT) as zf:
    for info in zf.infolist():
        print(f"  {info.filename:60s}  {info.file_size:>8d} bytes")
