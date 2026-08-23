#!/bin/zsh
set -euo pipefail

# Run the same-display ScreenCaptureKit vs CGDisplayStream cadence check from
# the exact installed SideScreen bundle, so the existing Screen Recording grant
# is evaluated under the canonical code identity.
#
# Usage:
#   ./scripts/run-capture-source-benchmark.sh <display-id> [duration-seconds]

display_id="${1:-}"
duration="${2:-10}"
bundle="/Users/redacted/Applications/SideScreen.app"
stdout_log="/tmp/sidescreen-capture-source-benchmark.stdout"
stderr_log="/tmp/sidescreen-capture-source-benchmark.stderr"

if [[ -z "$display_id" ]]; then
  echo "Usage: $0 <display-id> [duration-seconds]" >&2
  echo "Use the latest 'Capturing virtual display ... (ID: N)' line in /tmp/sidescreen.log." >&2
  exit 2
fi
if ! [[ "$display_id" =~ ^[0-9]+$ ]]; then
  echo "display-id must be numeric" >&2
  exit 2
fi
if ! [[ "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "duration must be numeric seconds" >&2
  exit 2
fi
if [[ ! -x "$bundle/Contents/MacOS/SideScreen" ]]; then
  echo "Missing canonical installed host: $bundle" >&2
  exit 3
fi

open -n -W -F --stdout "$stdout_log" --stderr "$stderr_log" "$bundle" --args \
  --capture-source-benchmark \
  --display-id "$display_id" \
  --duration "$duration"

echo "Benchmark output (also written to /tmp/sidescreen.log):"
cat "$stdout_log"
if [[ -s "$stderr_log" ]]; then
  echo "Benchmark stderr:"
  cat "$stderr_log"
fi
