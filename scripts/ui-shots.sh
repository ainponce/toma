#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Screenshots of one surface of the Debug app, for design work: launches build/Build/Products/Debug/Toma.app with
# -TomaShowcase <surface> [<path>] (or the library with -TomaLibraryBench), waits, writes a PNG of each of its windows
# into <folder>, and quits it. Needs Screen Recording for the app this runs in. Usage:
#   scripts/ui-shots.sh <folder> <surface> [<path>] [--wait <seconds>] [--appearance light|dark]
# surfaces: onboarding settings notices island editor <package> export <package> library <folder>
set -euo pipefail
cd "$(dirname "$0")/.."
out=$1; surface=$2; shift 2
path=""; wait=4; appearance=()
if [[ $# -gt 0 && $1 != --* ]]; then path=$1; shift; fi
while [[ $# -gt 0 ]]; do
  case $1 in
    --wait) wait=$2; shift 2 ;;
    # The app's Appearance setting for this run only (the argument domain): nothing is saved.
    --appearance) appearance=(-appearance "$2"); shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$out"
app=build/Build/Products/Debug/Toma.app/Contents/MacOS/Toma
if [[ $surface == library ]]; then
  "$app" -TomaLibraryBench "$path" -TomaLibraryBenchKeepOpen >/dev/null 2>&1 &
else
  "$app" -TomaShowcase "$surface" ${path:+"$path"} ${appearance[@]+"${appearance[@]}"} >/dev/null 2>&1 &
fi
pid=$!
sleep "$wait"
swift scripts/toma-window-shots.swift "$pid" "$out" "$surface"
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
