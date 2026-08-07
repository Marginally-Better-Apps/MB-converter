#!/usr/bin/env bash
# Record a headed iOS Simulator demo: Maestro taps + simctl io recordVideo.
# Usage: ./scripts/record-demo.sh e2e/demo/full-tour.yaml /tmp/mb-demo.mp4
set -euo pipefail

FLOW="${1:?Usage: $0 <maestro-flow.yaml> [output.mp4]}"
OUT="${2:-/tmp/mb-demo.mp4}"
APP_ID="${APP_ID:-com.marginallybetter.converter}"
DEVICE="${DEVICE:-}"

if ! command -v maestro >/dev/null 2>&1; then
  echo "error: maestro CLI not found (https://maestro.mobile.dev)" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: xcrun not found; install Xcode command line tools" >&2
  exit 1
fi

if [[ -z "$DEVICE" ]]; then
  DEVICE="$(xcrun simctl list devices booted | awk -F '[()]' '/Booted/{print $2; exit}')"
fi

if [[ -z "$DEVICE" ]]; then
  echo "error: no booted iOS Simulator; boot one first" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

echo "Recording on simulator $DEVICE → $OUT"
xcrun simctl io "$DEVICE" recordVideo --codec=h264 "$OUT" &
REC_PID=$!

cleanup() {
  if kill -0 "$REC_PID" 2>/dev/null; then
    kill -INT "$REC_PID" 2>/dev/null || true
    wait "$REC_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Give simctl a moment to start capturing before Maestro interacts.
sleep 1

# appId lives in the Maestro YAML; do not pass --app-id (unsupported on some CLI versions).
maestro test \
  --device "$DEVICE" \
  "$FLOW"

# Stop recording cleanly.
kill -INT "$REC_PID" 2>/dev/null || true
wait "$REC_PID" 2>/dev/null || true
trap - EXIT

if [[ ! -f "$OUT" ]]; then
  echo "error: expected video at $OUT" >&2
  exit 1
fi

echo "Demo saved: $OUT"
echo "Upload example:"
echo "  curl --fail-with-body -sS -H 'Content-Type: video/mp4' --data-binary @$OUT https://planista.shloklab.us/"
