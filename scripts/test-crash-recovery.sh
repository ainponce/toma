#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Crash test with synthetic sources (needs no permission): records a 20 s take, kills the recorder
# with SIGKILL 10 s in, recovers the take and verifies that every track kept at least 8 s, ends with
# the take and dropped at most 1 % of its frames. Once with a moving screen, once with a screen that
# stops changing after 2 s (heartbeats). After the first, an MP4 export of the recovered take is
# killed as soon as it is writing: the package must be unchanged, and the next export must succeed,
# leave nothing out (no "warning: no …" line: every recovered segment decodes) and last at least 8 s.
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

run_case() {  # $1 = extra flags for synth-record, $2 = "export" to crash an export of the recovered take
  local TMP PID PKG
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
  "$BIN" verify "$PKG" --min-duration 8 --max-drop-ratio 0.01
  if [ "${2:-}" = export ]; then export_crash "$PKG" "$TMP"; fi
  rm -rf "$TMP"
}

run_case "" export
run_case "--static-after 2"
echo "crash test passed"
