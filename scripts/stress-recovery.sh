#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Endurance and crash gate of phase 0, run by hand (it cannot run in CI): records the main display
# and the default microphone with content that moves the whole time, samples the recorder's memory
# at 5, 15 and 30 min, kills it with SIGKILL at 30 min, recovers the take and verifies that every
# track kept at least 1798 s. Prints, per track, its duration, droppedFrames and the endReason of
# each segment. Fails if a track was lost (trackLost) or there is no mic track.
#
#   bash scripts/stress-recovery.sh [folder]
#
# folder: where the package is recorded, created if needed (default: a new temporary folder). Point
# it at an external disk for the external-volume run. Write the results in docs/performance.md.
#
# Needs Screen Recording and Microphone permission for the terminal app, and about 4 GB free.
# The optional reboot test is described in docs/performance.md.
set -euo pipefail
cd "$(dirname "$0")/.."

DURATION=3600
KILL_AT=1800
MIN_DURATION=1798
RSS_AT=(300 900 1800)

DIR="${1:-$(mktemp -d)}"
mkdir -p "$DIR"
LOGS="$(mktemp -d)"

swift build -c release --package-path Packages/RecorderKit --product recorder-dev
BIN="$(swift build -c release --package-path Packages/RecorderKit --product recorder-dev --show-bin-path)/recorder-dev"

cat <<'EOF'
Before recording, on the main display:
  1. Open a Terminal window, make it full screen and run:
       while :; do date +%T.%N; sleep 0.05; done
  2. Leave it in front for the whole test (about 31 min). Do not lock the screen or let the Mac sleep.
EOF
read -r -p "Press Return to start recording... " _

PID=""
CAFFEINATE_PID=""
cleanup() {
  if [ -n "$PID" ]; then kill -9 "$PID" 2>/dev/null || true; fi
  if [ -n "$CAFFEINATE_PID" ]; then kill "$CAFFEINATE_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

caffeinate -dimsu -t 3700 &
CAFFEINATE_PID=$!

"$BIN" record "$DIR" --duration "$DURATION" > "$LOGS/out" 2> "$LOGS/err" &
PID=$!
until [ -s "$LOGS/out" ]; do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "FAIL: recorder-dev record exited before it started recording:"
    cat "$LOGS/err"
    exit 1
  fi
  sleep 0.1
done
PKG=$(head -1 "$LOGS/out")
START=$(date +%s)
echo "recording into $PKG (recorder pid $PID, logs in $LOGS)"

# Sleeps until `$1` seconds after START; fails if the recorder ended before.
wait_until() {
  while [ $(( $(date +%s) - START )) -lt "$1" ]; do
    if ! kill -0 "$PID" 2>/dev/null; then
      echo "FAIL: the recorder ended $(( $(date +%s) - START )) s in, before $1 s:"
      cat "$LOGS/out" "$LOGS/err"
      exit 1
    fi
    sleep 1
  done
}

for mark in "${RSS_AT[@]}"; do
  wait_until "$mark"
  RSS_KB=$(ps -o rss= -p "$PID" | tr -d ' ')
  echo "RSS at $(( mark / 60 )) min: ${RSS_KB} KB ($(( RSS_KB / 1024 )) MB)"
done

wait_until "$KILL_AT"
kill -9 "$PID"
wait "$PID" 2>/dev/null || true
PID=""
echo "killed the recorder with SIGKILL at $(( $(date +%s) - START )) s"

"$BIN" recover "$DIR"
if ! grep -q '"status" : "recovered"' "$PKG/manifest.json"; then
  echo "FAIL: the take was not marked recovered"
  exit 1
fi

VERIFY_STATUS=0
"$BIN" verify "$PKG" --min-duration "$MIN_DURATION" || VERIFY_STATUS=$?

# Per track, from the manifest: duration, droppedFrames and the endReason of each segment.
json() { plutil -extract "$1" raw -o - "$PKG/manifest.json"; }
TAKE=$(( $(json takes) - 1 ))
HAS_MIC=0
for (( i = 0; i < $(json "takes.$TAKE.tracks"); i++ )); do
  TRACK="takes.$TAKE.tracks.$i"
  ID=$(json "$TRACK.id")
  NANOSECONDS=0
  DROPPED=0
  REASONS=""
  for (( s = 0; s < $(json "$TRACK.segments"); s++ )); do
    SEGMENT="$TRACK.segments.$s"
    SEGMENT_START=$(json "$SEGMENT.startHostTime")
    SEGMENT_END=$(json "$SEGMENT.endHostTime" 2>/dev/null || echo "$SEGMENT_START")
    NANOSECONDS=$(( NANOSECONDS + SEGMENT_END - SEGMENT_START ))
    DROPPED=$(( DROPPED + $(json "$SEGMENT.droppedFrames") ))
    REASONS="$REASONS $(json "$SEGMENT.endReason.type" 2>/dev/null || echo open)"
  done
  printf '%s: %d.%03d s, droppedFrames %d, endReason%s\n' \
    "$ID" $(( NANOSECONDS / 1000000000 )) $(( NANOSECONDS % 1000000000 / 1000000 )) "$DROPPED" "$REASONS"
  if [ "$ID" = mic ]; then HAS_MIC=1; fi
done

# Export speed, once `recorder-dev export` exists (Task 11). It has no range option yet, so this
# times the whole recovered take, not only its first 10 min.
if "$BIN" --help | grep -qE '^ +export '; then
  EXPORT_START=$(date +%s)
  "$BIN" export "$PKG" "$LOGS/export.mp4" --width 1920 --height 1080 --fps 60
  echo "export at 1080p60: $(( $(date +%s) - EXPORT_START )) s for the whole take"
else
  echo "export: pending (recorder-dev export arrives with Task 11)"
fi

FAILED=0
if grep -q 'trackLost' "$LOGS/out"; then
  echo "FAIL: a track was lost:"
  grep 'trackLost' "$LOGS/out"
  FAILED=1
fi
if [ "$HAS_MIC" != 1 ]; then
  echo "FAIL: the take has no mic track"
  FAILED=1
fi
if [ "$VERIFY_STATUS" != 0 ]; then
  echo "FAIL: verify failed"
  FAILED=1
fi
if [ "$FAILED" != 0 ]; then exit 1; fi
echo "stress test passed: $PKG"
