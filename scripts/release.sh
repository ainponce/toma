#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds a release: dist/Toma.app, dist/Toma-<version>.dmg and dist/appcast.xml, the Sparkle feed with the
# DMG's EdDSA signature.
#   bash scripts/release.sh <version>          # for example 0.0.1
# Environment:
#   SIGN_IDENTITY           code signing identity (default "Toma Project Signing", made by
#                           scripts/create-signing-cert.sh); "-" signs ad hoc, to try the pipeline without it
#   DOWNLOAD_PREFIX         URL the DMG is downloaded from, ending in "/" (default http://localhost:8000/)
#   SPARKLE_ED_PRIVATE_KEY  Sparkle's private EdDSA key, as `generate_keys -x` exports it. Without it, the key
#                           in the login keychain is used; with neither, there is no appcast.
# The build number (CFBundleVersion) is the number of commits: git rev-list --count HEAD.
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:-}
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: bash scripts/release.sh <version>   (for example 0.0.1)" >&2
  exit 2
fi
identity=${SIGN_IDENTITY:-Toma Project Signing}
download_prefix=${DOWNLOAD_PREFIX:-http://localhost:8000/}
[[ $download_prefix == */ ]] || download_prefix+=/
build_number=$(git rev-list --count HEAD)

app=Toma
archive=build/$app.xcarchive
bundle=dist/$app.app
dmg=dist/$app-$version.dmg
staging=build/dmg-staging
sparkle_bin=build/SourcePackages/artifacts/sparkle/Sparkle/bin
keychain_service=https://sparkle-project.org  # where Sparkle's generate_keys keeps the private key

step() { printf '\n==> %s\n' "$*"; }
fail() {
  echo "release: $*" >&2
  exit 1
}
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$bundle/Contents/Info.plist" 2>/dev/null || true; }

# The launch test looks for a process with the app's name.
pgrep -x "$app" >/dev/null && fail "$app is running: quit it first (the launch test looks for a $app process)"

if [[ $identity != - ]]; then
  if ! security find-identity -v -p codesigning | grep -qF "\"$identity\""; then
    security find-identity -p codesigning | grep -F "\"$identity\"" ||
      fail "no code signing identity \"$identity\": run scripts/create-signing-cert.sh, or SIGN_IDENTITY=- for an ad hoc build"
    fail "\"$identity\" is in the keychain but not valid for code signing (is the certificate trusted for code signing?)"
  fi
fi
git diff --quiet HEAD -- || echo "release: warning: the working tree has uncommitted changes; they are in this build" >&2

step "Archiving $app $version (build $build_number), signed by \"$identity\""
rm -rf "$archive" dist "$staging"
mkdir -p dist
xcodegen generate
# netrc: resolving packages never waits on a keychain prompt for github.com credentials.
xcodebuild archive -quiet -project Toma.xcodeproj -scheme Toma -configuration Release -derivedDataPath build \
  -archivePath "$archive" -destination 'generic/platform=macOS' -packageAuthorizationProvider netrc \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number"
# The archive's app as it is: Xcode signed it last, after every change to the bundle.
ditto "$archive/Products/Applications/$app.app" "$bundle"

step "Checking the signature"
codesign --verify --deep --strict "$bundle"
echo "codesign --verify --deep --strict: valid"
details=$(codesign -dv --verbose=4 "$bundle" 2>&1)
grep -E '^(Identifier|Authority|TeamIdentifier|Signature)=|flags=' <<<"$details"
grep -q 'flags=.*runtime' <<<"$details" || fail "the hardened runtime is off"
if [[ $identity != - ]]; then
  grep -qxF "Authority=$identity" <<<"$details" || fail "not signed by \"$identity\""
fi
codesign -d -r- "$bundle" 2>&1 | grep 'designated =>'
entitlements=$(codesign -d --entitlements - "$bundle" 2>/dev/null)
grep -q 'com.apple.security.cs.disable-library-validation' <<<"$entitlements" ||
  fail "com.apple.security.cs.disable-library-validation is missing: without a Team ID, dyld rejects Sparkle.framework"
if grep -q 'com.apple.security.get-task-allow' <<<"$entitlements"; then
  fail "com.apple.security.get-task-allow is present: a release must not be debuggable"
fi
echo "entitlements: disable-library-validation present, get-task-allow absent"

[[ $(plist CFBundleShortVersionString) == "$version" ]] || fail "CFBundleShortVersionString is $(plist CFBundleShortVersionString), not $version"
[[ $(plist CFBundleVersion) == "$build_number" ]] || fail "CFBundleVersion is $(plist CFBundleVersion), not $build_number"
feed_url=$(plist SUFeedURL)
public_key=$(plist SUPublicEDKey)
[[ $feed_url == http*://*/* ]] || fail "SUFeedURL is \"$feed_url\" (in Config/Identity.xcconfig, write each // as /\$()/)"
echo "version $version, build $build_number, feed $feed_url, EdDSA public key ${public_key:-(none: updates are off in this build)}"

step "Launch test"
open "$bundle"
sleep 3
pid=$(pgrep -x "$app") || fail "$app did not stay up 3 s after opening"
echo "$app is running (pid $pid); quitting it"
kill "$pid"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.5
done
kill -0 "$pid" 2>/dev/null && fail "$app (pid $pid) did not quit"

step "Creating $dmg"
mkdir -p "$staging"
ditto "$bundle" "$staging/$app.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "$app $version" -srcfolder "$staging" -format UDZO -ov "$dmg"
rm -rf "$staging"
hdiutil verify -quiet "$dmg"
echo "hdiutil verify: checksum valid"

step "Appcast"
if [[ -n ${SPARKLE_ED_PRIVATE_KEY:-} ]]; then
  key_source="SPARKLE_ED_PRIVATE_KEY"
elif security find-generic-password -s "$keychain_service" -a ed25519 >/dev/null 2>&1; then
  key_source="the login keychain"
else
  echo "No EdDSA private key (neither SPARKLE_ED_PRIVATE_KEY nor Sparkle's key in the login keychain):"
  echo "skipping dist/appcast.xml. See docs/release.md for creating the key."
  key_source=
fi
if [[ -n $key_source ]]; then
  [[ -n $public_key ]] || fail "there is a private key but the app has no SUPublicEDKey: set SPARKLE_PUBLIC_KEY in Config/Identity.xcconfig"
  echo "Signing with the key from $key_source; downloads from $download_prefix"
  status=0
  if [[ -n ${SPARKLE_ED_PRIVATE_KEY:-} ]]; then
    output=$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" |
      "$sparkle_bin/generate_appcast" --ed-key-file - --download-url-prefix "$download_prefix" dist/ 2>&1) || status=$?
  else
    output=$("$sparkle_bin/generate_appcast" --download-url-prefix "$download_prefix" dist/ 2>&1) || status=$?
  fi
  echo "$output"
  ((status == 0)) || fail "generate_appcast failed (exit $status)"
  # generate_appcast only warns when the key doesn't match the app's, and writes an unsigned item.
  grep -qiE '^(warning|error)' <<<"$output" && fail "generate_appcast reported a problem (above)"
  [[ -f dist/appcast.xml ]] || fail "generate_appcast wrote no dist/appcast.xml"
  grep -q 'sparkle:edSignature=' dist/appcast.xml || fail "dist/appcast.xml has no EdDSA signature"
  grep -qF "url=\"$download_prefix$app-$version.dmg\"" dist/appcast.xml || fail "dist/appcast.xml does not point to $download_prefix$app-$version.dmg"
fi

step "Done"
ls -l dist
