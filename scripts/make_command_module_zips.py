#!/usr/bin/env python3
"""Build Magisk zips for nook_block_ota and nook_suppress_temp modules."""

import zipfile
from pathlib import Path

MODULES = [
    (
        Path("/tmp/nook_block_ota_module"),
        Path("/home/point/nook-gl4plus-tweaks/files/nook-gl4plus-block-ota-v1.zip"),
    ),
    (
        Path("/tmp/nook_suppress_temp_module"),
        Path("/home/point/nook-gl4plus-tweaks/files/nook-gl4plus-suppress-temp-v1.zip"),
    ),
]

for src, out in MODULES:
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(src.rglob("*")):
            if path.is_file():
                arcname = path.relative_to(src)
                zf.write(path, arcname)
    print(f"{out.name}  ({out.stat().st_size} bytes)")
    with zipfile.ZipFile(out) as zf:
        for info in zf.infolist():
            print(f"  {info.filename:55s}  {info.file_size:>6d} bytes")
    print()
