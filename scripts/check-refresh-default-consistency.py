#!/usr/bin/env python3
"""Guard against contradictory SideScreen refresh defaults.

Issue #31 found that DisplaySettings.init() falls back to 60 Hz while
resetToDefaults() restores 120 Hz. This script intentionally fails while those
values disagree so the source fix can be validated without relying on UI
inspection.

It is a local regression guard only; SideScreen does not use hosted CI as its
runtime acceptance boundary.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "MacHost" / "Sources" / "SettingsWindow.swift"

text = SOURCE.read_text(encoding="utf-8")

init_match = re.search(
    r"self\.refreshRate\s*=\s*defaults\.object\(forKey:\s*keyPrefix\s*\+\s*\"refreshRate\"\)\s*as\?\s*Int\s*\?\?\s*(\d+)",
    text,
)
reset_match = re.search(
    r"func\s+resetToDefaults\s*\(\s*\)\s*\{(?P<body>.*?)\n\s*\}",
    text,
    flags=re.S,
)

if init_match is None:
    print("ERROR: could not locate DisplaySettings init refresh fallback", file=sys.stderr)
    sys.exit(2)

if reset_match is None:
    print("ERROR: could not locate resetToDefaults()", file=sys.stderr)
    sys.exit(2)

reset_value_match = re.search(r"\brefreshRate\s*=\s*(\d+)", reset_match.group("body"))
if reset_value_match is None:
    print("ERROR: could not locate refreshRate assignment inside resetToDefaults()", file=sys.stderr)
    sys.exit(2)

init_default = int(init_match.group(1))
reset_default = int(reset_value_match.group(1))

print(f"fresh-init refresh default: {init_default} Hz")
print(f"reset refresh default:      {reset_default} Hz")

if init_default != reset_default:
    print(
        "FAIL: fresh-init and Reset Settings use different refresh defaults; "
        "see issue #31",
        file=sys.stderr,
    )
    sys.exit(1)

if init_default != 60:
    print(
        f"FAIL: canonical default is expected to remain 60 Hz until #3/#29 "
        f"target-hardware evidence explicitly changes policy (found {init_default})",
        file=sys.stderr,
    )
    sys.exit(1)

print("PASS: refresh defaults are consistent at 60 Hz")
