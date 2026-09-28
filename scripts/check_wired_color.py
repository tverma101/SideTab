#!/usr/bin/env python3
"""Check a tablet screenshot of Side Screen's wired color test pattern.

Requires ffmpeg. Capture with `adb exec-out screencap -p > chart.png` while
SideScreen_exp_pattern is color, gradient, or lowramp, then run this script.
The thresholds cover small codec rounding errors but reject the old
full-range-as-video-range clipping on the tested Samsung tablet.
"""

import argparse
import struct
import subprocess
from pathlib import Path


COLOR_PATCHES = (
    (255, 255, 255), (0, 0, 0), (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0),
    (0, 255, 255), (255, 0, 255), (245, 222, 179), (255, 140, 105), (135, 206, 250), (255, 215, 0),
    (64, 64, 64), (128, 128, 128), (192, 192, 192), (255, 99, 71), (60, 179, 113), (70, 130, 180),
    (255, 182, 193), (255, 228, 196), (176, 224, 230), (238, 130, 238), (255, 160, 122), (128, 0, 128),
)


def read_rgb(path: Path) -> tuple[int, int, bytes]:
    with path.open("rb") as image:
        header = image.read(24)
    if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError("expected a PNG screenshot")
    width, height = struct.unpack(">II", header[16:24])
    result = subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-i", str(path), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        capture_output=True,
        check=True,
    )
    if len(result.stdout) != width * height * 3:
        raise ValueError("decoded screenshot size does not match its PNG header")
    return width, height, result.stdout


def pixel(rgb: bytes, width: int, x: int, y: int) -> tuple[int, int, int]:
    offset = (y * width + x) * 3
    return tuple(rgb[offset:offset + 3])


def errors_for_pattern(pattern: str, width: int, height: int, rgb: bytes) -> list[int]:
    errors = []
    if pattern == "color":
        for index, expected in enumerate(COLOR_PATCHES):
            x = round((index % 6 + 0.5) * width / 6)
            y = round((index // 6 + 0.5) * height / 4)
            actual = pixel(rgb, width, x, y)
            errors.extend(abs(actual[channel] - expected[channel]) for channel in range(3))
    else:
        peak = 255 if pattern == "gradient" else 64
        for index in range(17):
            y = round(index * (height - 1) / 16)
            expected = y * peak // (height - 1)
            actual = pixel(rgb, width, width // 2, y)
            errors.extend(abs(channel - expected) for channel in actual)
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pattern", choices=("color", "gradient", "lowramp"))
    parser.add_argument("screenshot", type=Path)
    args = parser.parse_args()
    width, height, rgb = read_rgb(args.screenshot)
    errors = errors_for_pattern(args.pattern, width, height, rgb)
    mean_error = sum(errors) / len(errors)
    max_error = max(errors)
    passed = mean_error <= 2 and max_error <= (6 if args.pattern == "color" else 4)
    print(f"{args.pattern}: mean error {mean_error:.2f}, max error {max_error} — {'PASS' if passed else 'FAIL'}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
