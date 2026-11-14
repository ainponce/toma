#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Installs the pinned XcodeGen into <prefix> (bin/xcodegen and share/xcodegen/SettingPresets), for CI: its
# source release, checked against the SHA-256 that Homebrew's formula for this version records, built with
# SwiftPM the way that formula builds it (its dependencies are the revisions its Package.resolved pins). Never
# whatever `brew install` would bring that day.
#   bash scripts/install-xcodegen.sh <prefix>
set -euo pipefail

version=2.45.4
sha256=90705e5c410a980f7d98f75462bba2120de7c94b721cc06fd3f7e52a52a1aeed
prefix=${1:?usage: bash scripts/install-xcodegen.sh <prefix>}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  -o "$work/xcodegen.tar.gz" "https://github.com/yonaskolb/XcodeGen/archive/refs/tags/$version.tar.gz"
echo "$sha256  $work/xcodegen.tar.gz" | shasum -a 256 -c
tar -xzf "$work/xcodegen.tar.gz" -C "$work"
(cd "$work/XcodeGen-$version" && swift build --disable-sandbox -c release)
mkdir -p "$prefix/bin" "$prefix/share/xcodegen"
cp "$work/XcodeGen-$version/.build/release/xcodegen" "$prefix/bin/xcodegen"
cp -R "$work/XcodeGen-$version/SettingPresets" "$prefix/share/xcodegen/SettingPresets"
"$prefix/bin/xcodegen" --version
