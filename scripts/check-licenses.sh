#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Checks every dependency pinned in the app's and RecorderKit's Package.resolved. Its license, read from
# the LICENSE file of its resolved checkout, must be MIT, ISC, BSD (without the advertising clause),
# Apache-2.0, zlib, LGPL or GPL-3.0: compatible with GPL-3.0, never AGPL. It must also be listed, with that
# license text, in App/Resources/ThirdPartyNotices.txt, which the app shows. Run after the packages are
# resolved (make test resolves RecorderKit's, make build the app's):
#   bash scripts/check-licenses.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# The app's first: it pins every dependency of the app, Sparkle included, so it can't be empty.
app_resolved=Toma.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
resolved_files=("$app_resolved" Packages/RecorderKit/Package.resolved)
checkout_dirs=(build/SourcePackages/checkouts Packages/RecorderKit/.build/checkouts)
notices_file=App/Resources/ThirdPartyNotices.txt
allowed=(MIT ISC BSD Apache-2.0 zlib LGPL GPL-3.0)

fail() {
  echo "check-licenses: $*" >&2
  exit 1
}

# One value of a Package.resolved (JSON), or nothing when the key is missing.
value() {
  plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

# The license families named by a license file, one per line. Several files bundle more than one
# license (Sparkle's lists its external code); all of them count.
licenses_in() {
  local text
  text=$(tr -s '[:space:]' ' ' <"$1" | tr '[:upper:]' '[:lower:]')
  # The GPL family by their titles: GPL-3.0's text mentions the AGPL, and the LGPL's mentions the GPL.
  [[ $text == *"gnu affero general public license version 3, 19 november 2007"* ]] && echo AGPL
  [[ $text == *"gnu general public license version 3, 29 june 2007"* ]] && echo GPL-3.0
  [[ $text == *"gnu general public license version 2, june 1991"* ]] && echo GPL-2.0
  [[ $text == *"gnu lesser general public license version"* || $text == *"gnu library general public license version"* ]] && echo LGPL
  [[ $text == *"apache license version 2.0"* ]] && echo Apache-2.0
  [[ $text == *"permission is hereby granted, free of charge, to any person obtaining a copy"* ]] && echo MIT
  [[ $text == *"this software for any purpose with or without fee is hereby granted"* ]] && echo ISC
  [[ $text == *"redistribution and use in source and binary forms, with or without modification, are permitted"* ]] && echo BSD
  [[ $text == *"all advertising materials mentioning features or use of this software must display"* ]] && echo BSD-4-Clause
  [[ $text == *"and to alter it and redistribute it freely"* ]] && echo zlib
  return 0
}

is_allowed() {
  local family
  for family in "${allowed[@]}"; do
    [[ $1 == "$family" ]] && return 0
  done
  return 1
}

[[ -f $notices_file ]] || fail "$notices_file is missing"
notices=$(<"$notices_file")
checked=()
failures=0

for resolved in "${resolved_files[@]}"; do
  [[ -f $resolved ]] || fail "$resolved is missing: run make project and make build"
  format=$(value "$resolved" version)
  [[ $format == 2 || $format == 3 ]] || fail "$resolved: Package.resolved version $format is not supported"
  count=$(value "$resolved" pins)
  [[ $count =~ ^[0-9]+$ ]] || fail "$resolved has no list of pins"
  [[ $resolved != "$app_resolved" ]] || ((count > 0)) || fail "$resolved pins nothing: resolve the app's packages again (make build)"
  for ((i = 0; i < count; i++)); do
    identity=$(value "$resolved" "pins.$i.identity")
    kind=$(value "$resolved" "pins.$i.kind")
    location=$(value "$resolved" "pins.$i.location")
    revision=$(value "$resolved" "pins.$i.state.revision")
    version=$(value "$resolved" "pins.$i.state.version")
    [[ $kind == remoteSourceControl || $kind == localSourceControl ]] ||
      fail "$identity in $resolved: a $kind dependency can't be checked here"
    key="$identity@$revision"
    [[ " ${checked[*]-} " == *" $key "* ]] && continue
    checked+=("$key")

    # The resolved checkout of this pin, in either package build folder.
    name=$(basename "$location" .git)
    checkout=
    for dir in "${checkout_dirs[@]}"; do
      candidate="$dir/$name"
      [[ -d $candidate ]] || continue
      if [[ $(git -C "$candidate" rev-parse HEAD 2>/dev/null) == "$revision" ]]; then
        checkout=$candidate
        break
      fi
    done
    [[ -n $checkout ]] || fail "$identity ${version:-$revision}: no checkout at $revision in ${checkout_dirs[*]}; run make test and make build first"

    license=
    for candidate in LICENSE LICENSE.txt LICENSE.md LICENCE COPYING COPYING.txt; do
      if [[ -f $checkout/$candidate ]]; then
        license=$checkout/$candidate
        break
      fi
    done
    if [[ -z $license ]]; then
      echo "✘ $identity ${version:-$revision}: no LICENSE file in $checkout"
      failures=$((failures + 1))
      continue
    fi

    families=$(licenses_in "$license" | tr '\n' ' ')
    families=${families% }
    problems=()
    [[ -n $families ]] || problems+=("license not recognized; add it here only after checking it is GPL-3.0-compatible")
    for family in $families; do
      is_allowed "$family" || problems+=("$family is not allowed")
    done
    [[ $notices == *"$location"* ]] || problems+=("not listed in $notices_file")
    [[ $notices == *"$(<"$license")"* ]] || problems+=("its license text in $notices_file differs from $license")

    if ((${#problems[@]} == 0)); then
      echo "✔ $identity ${version:-$revision}: $families"
    else
      for problem in "${problems[@]}"; do
        echo "✘ $identity ${version:-$revision} (${families:-unknown}): $problem"
      done
      failures=$((failures + 1))
    fi
  done
done

if ((failures > 0)); then
  fail "$failures of ${#checked[@]} dependencies failed the license check"
fi
echo "check-licenses: ${#checked[@]} dependencies, all allowed"
