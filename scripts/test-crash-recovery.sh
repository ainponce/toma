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
# Sixth, the library (library_case): library-empty of a trash of 30 packages, killed at a random moment 20 times; after
# every kill, library-empty --finish-only must leave no Trash/.deleting-*, every package left in the trash must be whole
# and the 3 projects out of the trash must not change.
# Seventh, the GIF export (gif_case): export-gif of a 10 s take killed at a random moment 20 times; after every kill
# nothing has the final name, and the next export to the same destination finishes, removes the .partial.gif left and
# writes a GIF sips reads, with the bytes of the first one; the package never changes. Then the peak memory of
# export-gif (/usr/bin/time -l) of a 10 s and of a 60 s take at 800 px must be the same within 10 %.
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

# Runs edit-stress on package $1 with the flags after $2, killed at random, again and again (killed after 5 and then 10
# s) until a run reports a step saved past seq $2 (a run killed before its first saved step tells nothing), and checks
# the package after each: it must open again and take edits. Fails after three runs that saved nothing. Sets EXPECT to
# the seq the last run saved.
reopened_and_edited() {
  local PKG=$1 AFTER
  EXPECT=$2
  shift 2
  for AFTER in "$(kill_time)" 5 10; do
    stress_run "$PKG" "$AFTER" "$@"
    if [ "$CONFIRMED" -gt "$EXPECT" ]; then
      EXPECT=$CONFIRMED
      edit_check "$PKG" "$EXPECT" "$* after the kill"
      return
    fi
    edit_check "$PKG" "$EXPECT" "$* killed after $AFTER s before a saved step"
  done
  echo "FAIL: edit-stress $* saved no step past seq $EXPECT in three runs: the package does not take edits again"
  exit 1
}

# The editor (Task 13). First the first edit of a version 1 and of a version 2 package, killed by edit-stress itself
# after each step of the upgrade to version 3 (design §6.1: edit.lock taken, the manifest rewritten, the log written):
# the package must be the one it was (but for a stale edit.lock), a version 3 one with no edit, or one whose log holds
# that edit; then it must open and take edits again (a run killed at random that saved a step). Then a version 3
# package killed by edit-stress itself in the compaction of its log, after each step of the swap (the snapshot written,
# the new log written and synced, renamed over the old one): every step reported saved must be in the log, and it must
# open and take edits again. Then 100 edit-stress runs on one 3 s
# take, seeds 1…100, the even ones with --compact-every 50 (compacting at opening and at closing, which they do every 60
# steps), each killed with SIGKILL at a random moment from 0.2 to 2.0 s. After every kill, edit-check must find in the
# log every step reported saved by then (by that run or an earlier one, since the log never goes back), the project
# must open with the log's replay, undoing every group must lead back to the document it started with, and nothing may
# change a byte of the package meanwhile (edit-check writes nothing; no run touches takes/).
edit_case() {
  local PKG SEED HIGH=0 RUNS=0 TAKES VERSION POINT COPY ORIGINAL EXPECT FLAGS LINES STATE=good
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
      reopened_and_edited "$COPY" "$EXPECT" --seed "$SEED"
      if [ "$(package_hash "$COPY/takes")" != "$(package_hash "$PKG/takes")" ]; then
        echo "FAIL: the editor changed takes/ of the version $VERSION package"
        exit 1
      fi
      echo "opened again and edited: saved up to seq $EXPECT"
    done
  done
  echo "edit upgrade case passed (versions 1 and 2, killed after each of the 3 steps)"

  for POINT in after-snapshot after-temporary after-rename; do
    SEED=$((SEED + 1))
    COPY="$EDIT_TMP/compact-$POINT.toma"
    cp -R "$PKG" "$COPY"
    echo "== editor: a compaction of the log, kill -9 $POINT"
    # Compacting when the log has more than 5 lines: at the first close, after 60 steps.
    stress_run "$COPY" self --seed "$SEED" --compact-every 5 --kill-in-compaction "$POINT"
    if [ "$CONFIRMED" -lt 60 ]; then
      echo "FAIL: edit-stress --kill-in-compaction $POINT saved only up to seq $CONFIRMED before the compaction"
      exit 1
    fi
    # Killed where it says: the old log whole beside an empty or a whole new one, or the new one in its place.
    LINES=$(wc -l < "$COPY/edit-log.jsonl" | tr -d " ")
    case $POINT in
      after-snapshot) if [ ! -f "$COPY/edit-log.jsonl.tmp" ] || [ -s "$COPY/edit-log.jsonl.tmp" ] || [ "$LINES" -lt "$CONFIRMED" ]; then STATE=bad; fi ;;
      after-temporary) if [ ! -s "$COPY/edit-log.jsonl.tmp" ] || [ "$LINES" -lt "$CONFIRMED" ]; then STATE=bad; fi ;;
      after-rename) if [ -e "$COPY/edit-log.jsonl.tmp" ] || [ "$LINES" -ge "$CONFIRMED" ]; then STATE=bad; fi ;;
    esac
    if [ "$STATE" = bad ]; then
      echo "FAIL: after a kill $POINT the log has $LINES lines for seq $CONFIRMED, and edit-log.jsonl.tmp is:"
      ls -l "$COPY/edit-log.jsonl.tmp" 2>&1
      exit 1
    fi
    EXPECT=$CONFIRMED
    edit_check "$COPY" "$EXPECT" "--kill-in-compaction $POINT"
    reopened_and_edited "$COPY" "$EXPECT" --seed "$SEED"
    if [ "$(package_hash "$COPY/takes")" != "$(package_hash "$PKG/takes")" ]; then
      echo "FAIL: the editor changed takes/ in the compaction case"
      exit 1
    fi
    echo "every saved step kept; opened again and edited: saved up to seq $EXPECT"
  done
  echo "edit compaction case passed (killed after each of the 3 steps of the swap)"

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

# A moment from 0.05 to 0.5 s, at random.
library_kill_time() {
  LC_ALL=C awk -v r="$RANDOM" 'BEGIN { printf "%.3f", 0.05 + 0.45 * r / 32767 }'
}

# A synthetic package at $1, with $2 written into it: a manifest, a document, a log, 1 MB of "media" and 200 small files
# of cache, so that deleting it takes a while.
synthetic_package() {
  local I
  mkdir -p "$1/takes/take-001/display-1" "$1/cache/thumbnails"
  printf '{"formatVersion":3,"name":"%s"}\n' "$2" > "$1/manifest.json"
  printf '{"documentVersion":2}\n' > "$1/edit.json"
  printf '{"seq":1}\n' > "$1/edit-log.jsonl"
  head -c 1048576 /dev/urandom > "$1/takes/take-001/display-1/seg-0001.mov"
  for I in $(seq 1 200); do printf '%s %s\n' "$2" "$I" > "$1/cache/thumbnails/$I.heic"; done
}

# One hash of the 3 projects out of the trash of the projects folder $1.
outside_hash() {
  local PACKAGE
  for PACKAGE in "Outside 1.toma" "Outside 2.toma" "Clientes/Outside 3.toma"; do package_hash "$1/$PACKAGE"; done | shasum
}

# The library (Task 33): a trash of 30 synthetic packages and 3 projects out of it (two in the projects folder, one in a
# subfolder). Every package of the trash has a link to one of those projects and one to a file of another: deleting must
# never follow a link. 20 runs of library-empty (LibraryOperations.deleteForever), each killed with SIGKILL at a random
# moment from 0.05 to 0.5 s (or finished before), the trash filled up to 30 again before each. After every kill, with a
# link named .deleting-planted to the subfolder put in the trash, library-empty --finish-only (finishPendingDeletions)
# must leave no Trash/.deleting-* (the link removed, never followed), every package left in the trash must be whole (a
# package is deleted only once it was renamed away) and the 3 projects out of the trash must not change a byte.
library_case() {
  local DIR PROJECTS TRASH TEMPLATE WHOLE OUTSIDE RUN I PID STATUS MID=0 PACKAGE
  DIR=$(mktemp -d)
  PROJECTS="$DIR/Projects"
  TRASH="$PROJECTS/Trash"
  echo "== library: library-empty of a trash of 30 packages, kill -9 at random, 20 times (in $DIR)"
  mkdir -p "$TRASH" "$PROJECTS/Clientes"
  synthetic_package "$PROJECTS/Outside 1.toma" "outside 1"
  synthetic_package "$PROJECTS/Outside 2.toma" "outside 2"
  synthetic_package "$PROJECTS/Clientes/Outside 3.toma" "outside 3"
  OUTSIDE=$(outside_hash "$PROJECTS")
  TEMPLATE="$DIR/template.toma"
  synthetic_package "$TEMPLATE" "in the trash"
  ln -s "$PROJECTS/Outside 1.toma" "$TEMPLATE/link-to-a-project"
  ln -s "$PROJECTS/Clientes/Outside 3.toma/manifest.json" "$TEMPLATE/takes/take-001/link-to-a-file"
  WHOLE=$(package_hash "$TEMPLATE")
  for RUN in $(seq 1 20); do
    for I in $(seq 1 30); do
      if [ ! -e "$TRASH/P $I.toma" ]; then cp -cR "$TEMPLATE" "$TRASH/P $I.toma"; fi
    done
    STATUS=0
    "$BIN" library-empty "$PROJECTS" > "$DIR/empty.out" 2> "$DIR/empty.err" &
    PID=$!
    sleep "$(library_kill_time)"
    kill -9 "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || STATUS=$?
    if [ "$STATUS" -ne 137 ] && [ "$STATUS" -ne 0 ]; then
      echo "FAIL: library-empty ended with status $STATUS:"
      cat "$DIR/empty.err"
      exit 1
    fi
    if ls -A "$TRASH" | grep -q '^\.deleting-'; then MID=$((MID + 1)); fi
    ln -s "$PROJECTS/Clientes" "$TRASH/.deleting-planted"
    if ! "$BIN" library-empty "$PROJECTS" --finish-only; then
      echo "FAIL: library-empty --finish-only failed after run $RUN"
      exit 1
    fi
    if ls -A "$TRASH" | grep -q '^\.deleting-'; then
      echo "FAIL: library-empty --finish-only left in the trash after run $RUN:"
      ls -A "$TRASH" | grep '^\.deleting-'
      exit 1
    fi
    for PACKAGE in "$TRASH"/*.toma; do
      [ -e "$PACKAGE" ] || continue
      if [ "$(package_hash "$PACKAGE")" != "$WHOLE" ]; then
        echo "FAIL: $PACKAGE was left in the trash in part after run $RUN"
        exit 1
      fi
    done
    if [ "$(outside_hash "$PROJECTS")" != "$OUTSIDE" ]; then
      echo "FAIL: the projects out of the trash changed after run $RUN"
      exit 1
    fi
  done
  if [ "$MID" -eq 0 ]; then
    echo "FAIL: no run was killed in the middle of a deletion: nothing was checked"
    exit 1
  fi
  echo "$MID of 20 runs killed in the middle of a deletion; $(find "$TRASH" -maxdepth 1 -name '*.toma' | wc -l | tr -d ' ') packages left in the trash, whole"
  rm -rf "$DIR"
  echo "library crash case passed (20 runs)"
}

# The peak memory footprint, in bytes, of export-gif of package $1 into $2, from /usr/bin/time -l (with its maximum
# resident set size after it); fails if the export does.
gif_peak() {
  local OUT
  OUT=$(mktemp)
  if ! /usr/bin/time -l "$BIN" export-gif "$1" "$2" > /dev/null 2> "$OUT"; then
    echo "FAIL: export-gif $1 failed:" >&2
    cat "$OUT" >&2
    exit 1
  fi
  awk '/peak memory footprint/ { peak = $1 } /maximum resident set size/ { rss = $1 } END { print peak + 0, rss + 0 }' "$OUT"
  rm -f "$OUT"
}

# The GIF export (Task 22, 1c design §7.4 and §16.1): 20 runs of export-gif of a 10 s synth-record take (800 px, 15 fps),
# each killed with SIGKILL at a random moment from 0.2 to 2.0 s. After every kill nothing may have the final name; then
# export-gif to the same destination must finish, remove the .partial.gif the kill left and write a GIF that sips reads
# as 800 px wide and that has the bytes of the first one (every export is a process of its own: the same project and
# options give the same GIF); it is removed before the next run, so the next kill is checked against no file again. No
# export, killed or not, may change a byte of the package. Then the peak
# memory (H19, in processes of their own: a test run measures every test at once): export-gif of a 10 s and of a 60 s
# take at 800 px must reach the same peak memory footprint within 10 %, the memory not growing with the duration.
gif_case() {
  local DIR PKG BEFORE LONG RUN PID STATUS PARTIALS=0 WIDTH PEAKS SHORT SHORT_RSS LONG_PEAK LONG_RSS
  DIR=$(mktemp -d)
  echo "== GIF: export-gif of a 10 s take, kill -9 at random, 20 times (in $DIR)"
  "$BIN" synth-record "$DIR" --duration 10 > "$DIR/short.out"
  PKG=$(head -1 "$DIR/short.out")
  BEFORE=$(package_hash "$PKG")
  for RUN in $(seq 1 20); do
    STATUS=0
    "$BIN" export-gif "$PKG" "$DIR/out.gif" > "$DIR/gif.out" 2> "$DIR/gif.err" &
    PID=$!
    sleep "$(kill_time)"
    kill -9 "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || STATUS=$?
    if [ "$STATUS" -ne 137 ]; then
      echo "FAIL: export-gif was not killed as expected in run $RUN (status $STATUS):"
      cat "$DIR/gif.err"
      exit 1
    fi
    if [ -e "$DIR/out.gif" ]; then
      echo "FAIL: a killed export-gif left out.gif in run $RUN"
      exit 1
    fi
    if [ -e "$DIR/out.gif.partial.gif" ]; then PARTIALS=$((PARTIALS + 1)); fi
    if ! "$BIN" export-gif "$PKG" "$DIR/out.gif" > "$DIR/gif.out" 2> "$DIR/gif.err"; then
      echo "FAIL: export-gif after the kill of run $RUN failed:"
      cat "$DIR/gif.err"
      exit 1
    fi
    if [ -e "$DIR/out.gif.partial.gif" ] || [ ! -s "$DIR/out.gif" ]; then
      echo "FAIL: export-gif after the kill of run $RUN did not leave a finished out.gif and nothing else"
      exit 1
    fi
    WIDTH=$(sips -g pixelWidth "$DIR/out.gif" 2>/dev/null | awk '/pixelWidth/ { print $2 }')
    if [ "$WIDTH" != 800 ]; then
      echo "FAIL: sips does not read the GIF of run $RUN as 800 px wide (${WIDTH:-no width})"
      exit 1
    fi
    if [ "$RUN" -eq 1 ]; then
      mv "$DIR/out.gif" "$DIR/first.gif"
    elif ! cmp -s "$DIR/first.gif" "$DIR/out.gif"; then
      echo "FAIL: the GIF of run $RUN does not have the bytes of the first one"
      exit 1
    else
      rm "$DIR/out.gif"
    fi
    if [ "$(package_hash "$PKG")" != "$BEFORE" ]; then
      echo "FAIL: export-gif changed the package in run $RUN"
      exit 1
    fi
  done
  if [ "$PARTIALS" -eq 0 ]; then
    echo "FAIL: no run was killed while it wrote out.gif.partial.gif: nothing was checked"
    exit 1
  fi
  tail -1 "$DIR/gif.out"
  echo "$PARTIALS of 20 runs killed while writing out.gif.partial.gif; every next export finished, removed it and wrote" \
    "the same bytes; the package did not change"

  echo "== GIF: the peak memory of export-gif of a 10 s and of a 60 s take"
  "$BIN" synth-record "$DIR" --duration 60 > "$DIR/long.out"
  LONG=$(head -1 "$DIR/long.out")
  PEAKS=$(gif_peak "$PKG" "$DIR/short.gif")
  read -r SHORT SHORT_RSS <<< "$PEAKS"
  PEAKS=$(gif_peak "$LONG" "$DIR/long.gif")
  read -r LONG_PEAK LONG_RSS <<< "$PEAKS"
  echo "peak memory footprint: $((SHORT >> 20)) MB for 10 s, $((LONG_PEAK >> 20)) MB for 60 s" \
    "(maximum resident set size: $((SHORT_RSS >> 20)) MB, $((LONG_RSS >> 20)) MB)"
  if ! awk -v s="$SHORT" -v l="$LONG_PEAK" 'BEGIN { exit !(s > 0 && l <= s * 1.1 && l >= s * 0.9) }'; then
    echo "FAIL: the peak memory of a GIF of 60 s is not that of one of 10 s within 10 %"
    exit 1
  fi
  rm -rf "$DIR"
  echo "gif crash case passed (20 runs)"
}

run_case "" export
run_case "--static-after 2"
run_case "--displays 2 --camera --system-audio" export "display-1 display-2 camera mic system-audio"
run_case "--window" "" "window-4242 mic"
edit_case
library_case
gif_case
echo "crash test passed"
