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
# Fifth, the editor (edit_case): the first edit of a version 1 and of a version 2 package killed after each
# step of its upgrade to version 3, then 100 edit-stress runs on a 3 s take, each killed at a random moment:
# after every kill, edit-check must find every step the editor reported saved, and the project must open.
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

# One hash of every file in package $1 (manifest.json included) with its path; with $2, every file but the one of
# that name at the top of the package.
package_hash() {
  (cd "$1" && find . -type f ! -path "./${2:-}" -print0 | sort -z | xargs -0 shasum) | shasum
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

# The editor's case keeps its files, its caches among them, in this folder.
EDIT_TMP=""

# A moment from 0.2 to 2.0 s, at random.
kill_time() {
  LC_ALL=C awk -v r="$RANDOM" 'BEGIN { printf "%.3f", 0.2 + 1.8 * r / 32767 }'
}

# Runs edit-stress on package $1 with the flags after $2 and kills it with SIGKILL after $2 seconds; with $2 "self",
# waits for it to kill itself (--kill-in-upgrade). Fails if it ended in any other way. Sets CONFIRMED to the seq of the
# last "confirmed" line it printed, 0 without one: the last step it reported saved.
stress_run() {
  local PKG=$1 AFTER=$2 PID STATUS=0 WAITED=0
  shift 2
  "$BIN" edit-stress "$PKG" --caches "$EDIT_TMP/caches" "$@" > "$EDIT_TMP/stress.out" 2> "$EDIT_TMP/stress.err" &
  PID=$!
  if [ "$AFTER" = self ]; then
    # One edit and the upgrade it starts: 120 s is only there so that a hang fails instead of waiting forever. Without
    # the redirection, bash tells of the kill ("Killed: 9") as it notices it, in the loop.
    {
      while kill -0 "$PID" 2>/dev/null && [ "$WAITED" -lt 1200 ]; do
        sleep 0.1
        WAITED=$((WAITED + 1))
      done
    } 2>/dev/null
    if [ "$WAITED" -ge 1200 ]; then kill -9 "$PID" 2>/dev/null || true; fi
  else
    sleep "$AFTER"
    kill -9 "$PID" 2>/dev/null || true
  fi
  wait "$PID" 2>/dev/null || STATUS=$?
  if [ "$STATUS" -ne 137 ] || [ "$WAITED" -ge 1200 ]; then
    echo "FAIL: edit-stress $* was not killed as expected (status $STATUS):"
    cat "$EDIT_TMP/stress.err"
    exit 1
  fi
  CONFIRMED=$(awk '/^confirmed [0-9]+$/ { seq = $2 } END { print seq + 0 }' "$EDIT_TMP/stress.out")
}

# edit-check of package $1 with --confirmed $2, after edit-stress $3: it must pass and leave every file of the package
# as it was.
edit_check() {
  local PKG=$1 BEFORE
  BEFORE=$(package_hash "$PKG")
  if ! "$BIN" edit-check "$PKG" --confirmed "$2" > "$EDIT_TMP/check.out" 2>&1; then
    echo "FAIL: edit-check --confirmed $2 after edit-stress $3:"
    cat "$EDIT_TMP/check.out"
    exit 1
  fi
  if [ "$(package_hash "$PKG")" != "$BEFORE" ]; then
    echo "FAIL: edit-check changed the package after edit-stress $3"
    exit 1
  fi
}

# A copy at $2 of package $1 (version 3, never edited) as a version $3 (1 or 2) app would have written it: the
# manifest at that version and without projectID, as TakeBuilder(formatVersion:) makes it.
legacy_copy() {
  cp -R "$1" "$2"
  sed -i '' -e "s/^  \"formatVersion\" : 3,\$/  \"formatVersion\" : $3,/" -e '/^  "projectID" : /d' "$2/manifest.json"
  if ! grep -q "^  \"formatVersion\" : $3,\$" "$2/manifest.json" || grep -q '"projectID"' "$2/manifest.json"; then
    echo "FAIL: could not write a version $3 manifest into $2"
    exit 1
  fi
}

# The editor (Task 13). First the first edit of a version 1 and of a version 2 package, killed by edit-stress itself
# after each step of the upgrade to version 3 (design §6.1: edit.lock taken, the manifest rewritten, the log written):
# the package must be the one it was (but for a stale edit.lock), a version 3 one with no edit, or one whose log holds
# that edit; then it must open and take edits again (one run killed at random). Then 100 edit-stress runs on one 3 s
# take, seeds 1…100, the even ones with --compact-every 50 (compacting at opening and at closing, which they do every 60
# steps), each killed with SIGKILL at a random moment from 0.2 to 2.0 s. After every kill, edit-check must find in the
# log every step reported saved by then (by that run or an earlier one, since the log never goes back), the project
# must open with the log's replay, undoing every group must lead back to the document it started with, and nothing may
# change a byte of the package meanwhile (edit-check writes nothing; no run touches takes/).
edit_case() {
  local PKG SEED HIGH=0 RUNS=0 TAKES VERSION POINT COPY ORIGINAL EXPECT FLAGS
  EDIT_TMP=$(mktemp -d)
  echo "== editor: synth-record --duration 3 (in $EDIT_TMP)"
  "$BIN" synth-record "$EDIT_TMP" --duration 3 > "$EDIT_TMP/out"
  PKG=$(head -1 "$EDIT_TMP/out")

  SEED=100
  for VERSION in 1 2; do
    for POINT in after-lock after-manifest after-log; do
      SEED=$((SEED + 1))
      COPY="$EDIT_TMP/v$VERSION-$POINT.toma"
      legacy_copy "$PKG" "$COPY" "$VERSION"
      ORIGINAL=$(package_hash "$COPY")
      echo "== editor: first edit of a version $VERSION package, kill -9 $POINT"
      stress_run "$COPY" self --seed "$SEED" --kill-in-upgrade "$POINT"
      case $POINT in
        after-lock)
          if [ ! -f "$COPY/edit.lock" ] || [ "$(package_hash "$COPY" edit.lock)" != "$ORIGINAL" ]; then
            echo "FAIL: the version $VERSION package is not as it was, with edit.lock, after a kill with the lock taken"
            exit 1
          fi
          EXPECT=0
          ;;
        after-manifest)
          if ! grep -q '^  "formatVersion" : 3,$' "$COPY/manifest.json" \
            || ! grep -q "^  \"upgradedFrom\" : $VERSION\$" "$COPY/manifest.json" || [ -e "$COPY/edit-log.jsonl" ]; then
            echo "FAIL: after a kill between the manifest and the log, the package is not a version 3 one without a log"
            exit 1
          fi
          EXPECT=0
          ;;
        after-log)
          if ! grep -q '^  "formatVersion" : 3,$' "$COPY/manifest.json" || [ ! -s "$COPY/edit-log.jsonl" ]; then
            echo "FAIL: after a kill once the log was written, the package is not a version 3 one with its log"
            exit 1
          fi
          # Its create and the first edit, at seq 2.
          EXPECT=2
          ;;
      esac
      edit_check "$COPY" "$EXPECT" "--kill-in-upgrade $POINT"
      stress_run "$COPY" "$(kill_time)" --seed "$SEED"
      if [ "$CONFIRMED" -gt "$EXPECT" ]; then EXPECT=$CONFIRMED; fi
      edit_check "$COPY" "$EXPECT" "--seed $SEED after --kill-in-upgrade $POINT"
      if [ "$(package_hash "$COPY/takes")" != "$(package_hash "$PKG/takes")" ]; then
        echo "FAIL: the editor changed takes/ of the version $VERSION package"
        exit 1
      fi
      echo "opened again and edited: saved up to seq $EXPECT at least"
    done
  done
  echo "edit upgrade case passed (versions 1 and 2, killed after each of the 3 steps)"

  TAKES=$(package_hash "$PKG/takes")
  for SEED in $(seq 1 100); do
    FLAGS="--seed $SEED"
    if [ $((SEED % 2)) -eq 0 ]; then FLAGS="$FLAGS --compact-every 50"; fi
    # shellcheck disable=SC2086  # $FLAGS holds the flags
    stress_run "$PKG" "$(kill_time)" $FLAGS
    if [ "$CONFIRMED" -gt 0 ]; then RUNS=$((RUNS + 1)); fi
    if [ "$CONFIRMED" -gt "$HIGH" ]; then HIGH=$CONFIRMED; fi
    edit_check "$PKG" "$HIGH" "$FLAGS"
    if [ $((SEED % 10)) -eq 0 ]; then
      echo "== edit-stress seeds $((SEED - 9))…$SEED: $RUNS runs so far killed after a saved step, saved up to seq $HIGH"
    fi
  done
  if [ "$RUNS" -eq 0 ]; then
    echo "FAIL: no run saved a step before it was killed: nothing was checked"
    exit 1
  fi
  if [ "$(package_hash "$PKG/takes")" != "$TAKES" ]; then
    echo "FAIL: the editor changed takes/"
    exit 1
  fi
  tail -1 "$EDIT_TMP/check.out"
  echo "$RUNS of 100 runs killed after a saved step; the log has $(wc -l < "$PKG/edit-log.jsonl" | tr -d " ") lines"
  rm -rf "$EDIT_TMP"
  echo "edit crash case passed (100 runs, 50 with compaction)"
}

run_case "" export
run_case "--static-after 2"
run_case "--displays 2 --camera --system-audio" export "display-1 display-2 camera mic system-audio"
run_case "--window" "" "window-4242 mic"
edit_case
echo "crash test passed"
