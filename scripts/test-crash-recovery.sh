#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Crash test with synthetic sources (needs no permission): records a 20 s take, kills the recorder
# with SIGKILL 10 s in, recovers the take and verifies that every track kept at least 8 s, ends with
# the take and dropped at most 1 % of its frames. Once with a moving screen, once with a screen that
# stops changing after 2 s (heartbeats). Run with `make crash-test`.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$(swift build --package-path Packages/RecorderKit --product recorder-dev --show-bin-path)/recorder-dev"
swift build --package-path Packages/RecorderKit --product recorder-dev

run_case() {  # $1 = extra flags for synth-record
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
  rm -rf "$TMP"
}

run_case ""
run_case "--static-after 2"
echo "crash test passed"
