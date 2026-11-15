#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Crash test with synthetic sources (needs no permission): records a 20 s take, kills the recorder
# with SIGKILL 10 s in, recovers the take and verifies that every track kept at least 8 s, ends with
# the take and dropped at most 1 % of its frames. Four times: with a moving screen; with a screen that
# stops changing after 2 s (heartbeats); with five tracks, every kind but a window (two displays, a
# camera, the microphone and system audio), each of which verify must pass; and with a window instead
# of a display (the window and the microphone). After the first and the third, an MP4 export of the
# recovered take is killed as soon as it is writing: the package must be unchanged, and the next export
# must succeed, leave nothing out (no "warning: no …" line: every recovered segment decodes) and last at
# least 8 s.
# Run with `make crash-test`.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$(swift build --package-path Packages/RecorderKit --product recorder-dev --show-bin-path)/recorder-dev"
swift build --package-path Packages/RecorderKit --product recorder-dev

# Kills an export of package $1 into folder $2 once it is writing (its partial file exists), checks that
# the package did not change and that nothing reached the destination, then exports again and checks
# that it worked.
export_crash() {
  local PKG=$1 TMP=$2 BEFORE EPID WAITED=0
  echo "== export, kill -9 while it writes"
  BEFORE=$(package_hash "$PKG")
  "$BIN" export "$PKG" "$TMP/out.mp4" > "$TMP/export.out" &
  EPID=$!
  until [ -e "$TMP/out.mp4.partial.mp4" ]; do
    # It exited, finished already, or wrote nothing for 20 s.
    if ! kill -0 "$EPID" 2>/dev/null || [ -e "$TMP/out.mp4" ] || [ "$WAITED" -ge 200 ]; then
      echo "FAIL: the export could not be caught while writing its partial file"
      kill -9 "$EPID" 2>/dev/null || true
      wait "$EPID" 2>/dev/null || true
      exit 1
    fi
    sleep 0.1
    WAITED=$((WAITED + 1))
  done
  sleep 0.3  # a few frames into the file
  kill -9 "$EPID"
  wait "$EPID" 2>/dev/null || true
  if [ -e "$TMP/out.mp4" ] || [ ! -e "$TMP/out.mp4.partial.mp4" ]; then
    echo "FAIL: the export was not cut off while writing (it finished first)"
    exit 1
  fi
  if [ "$(package_hash "$PKG")" != "$BEFORE" ]; then
    echo "FAIL: the killed export changed the package"
    exit 1
  fi
  "$BIN" export "$PKG" "$TMP/out.mp4" > "$TMP/export.out"
  tail -1 "$TMP/export.out"
  if [ ! -s "$TMP/out.mp4" ] || [ -e "$TMP/out.mp4.partial.mp4" ]; then
    echo "FAIL: the second export did not leave a finished out.mp4 and nothing else"
    exit 1
  fi
  if [ "$(package_hash "$PKG")" != "$BEFORE" ]; then
    echo "FAIL: the export changed the package"
    exit 1
  fi
  if grep -q '^warning: no ' "$TMP/export.out"; then
    echo "FAIL: the export left out part of the recovered take:"
    grep '^warning: no ' "$TMP/export.out"
    exit 1
  fi
  # The MP4's length, from its audio track (the take has a microphone).
  local SECONDS_EXPORTED
  SECONDS_EXPORTED=$(afinfo "$TMP/out.mp4" | awk '/estimated duration/ { print $3; exit }')
  if ! awk -v d="${SECONDS_EXPORTED:-0}" 'BEGIN { exit !(d >= 8) }'; then
    echo "FAIL: the export lasts ${SECONDS_EXPORTED:-an unknown number of} s, less than 8 s"
    exit 1
  fi
  echo "export: ${SECONDS_EXPORTED} s, nothing left out"
}

# One hash of every file in package $1 (manifest.json included) with its path.
package_hash() {
  (cd "$1" && find . -type f -print0 | sort -z | xargs -0 shasum) | shasum
}

# $1 = extra flags for synth-record, $2 = "export" to crash an export of the recovered take (or ""), $3 = the
# tracks verify must pass, all of them and only them (optional).
run_case() {
  local TMP PID PKG TRACK
  TMP=$(mktemp -d)
  echo "== synth-record --duration 20 $1, kill -9 at 10 s (in $TMP)"
  # shellcheck disable=SC2086  # $1 holds zero or more flags
  "$BIN" synth-record "$TMP" --duration 20 $1 > "$TMP/out" &
  PID=$!
  until [ -s "$TMP/out" ]; do
    if ! kill -0 "$PID" 2>/dev/null; then
      echo "FAIL: synth-record exited before it started recording"
      wait "$PID" || true
      exit 1
    fi
    sleep 0.1
  done
  PKG=$(head -1 "$TMP/out")
  sleep 10
  kill -9 "$PID"
  wait "$PID" 2>/dev/null || true
  "$BIN" recover "$TMP"
  if ! grep -q '"status" : "recovered"' "$PKG/manifest.json"; then
    echo "FAIL: the take was not marked recovered"
    exit 1
  fi
  "$BIN" verify "$PKG" --min-duration 8 --max-drop-ratio 0.01 | tee "$TMP/verify.out"
  if [ -n "${3:-}" ]; then
    for TRACK in $3; do
      if ! grep -q "^OK: $TRACK " "$TMP/verify.out"; then
        echo "FAIL: verify did not pass $TRACK"
        exit 1
      fi
    done
    # shellcheck disable=SC2086  # $3 holds the track names
    if [ "$(grep -c '^OK: ' "$TMP/verify.out")" -ne "$(set -- $3; echo $#)" ]; then
      echo "FAIL: verify checked other tracks than $3"
      exit 1
    fi
  fi
  if [ "${2:-}" = export ]; then export_crash "$PKG" "$TMP"; fi
  rm -rf "$TMP"
}

run_case "" export
run_case "--static-after 2"
run_case "--displays 2 --camera --system-audio" export "display-1 display-2 camera mic system-audio"
run_case "--window" "" "window-4242 mic"
echo "crash test passed"
