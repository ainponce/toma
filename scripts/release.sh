#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds a release: dist/Toma.app, dist/Toma-<version>.dmg and dist/appcast.xml, the Sparkle feed with the
# DMG's EdDSA signature. Earlier DMGs and the appcast already in dist/ are kept: generate_appcast adds the new
# version to that appcast, with delta updates from those DMGs. The app and the DMG carry the GPL (LICENSE).
#   bash scripts/release.sh <version>          # for example 0.0.1
# Environment:
#   SIGN_IDENTITY           code signing identity (default "Toma Project Signing", made by
#                           scripts/create-signing-cert.sh); "-" signs ad hoc, to try the pipeline without it.
#                           An ad hoc build writes everything to build/adhoc-dist/ and never touches dist/, the
#                           release history, nor the login keychain.
#   DOWNLOAD_PREFIX         URL the DMG is downloaded from, ending in "/" (default http://localhost:8000/)
#   SOURCE_CODE_URL         the repository the source code is published at (overrides Config/Identity.xcconfig);
#                           the app shows it, at the tag of this version, in Acknowledgements
#   SPARKLE_ED_PRIVATE_KEY  Sparkle's private EdDSA key, as `generate_keys -x` exports it. Without it, a signed
#                           build uses the key in the login keychain; with neither, there is no appcast. An ad
#                           hoc build makes an appcast only with this variable, meant as a throwaway key. Only
#                           generate_appcast sees it: it is taken out of the environment first.
# The build number (CFBundleVersion) is the number of commits: git rev-list --count HEAD. Packages are the
# versions pinned in the Package.resolved files, never newer ones.
set -euo pipefail
# Sparkle's private key can never be revoked: nothing this script runs but generate_appcast may see it, not
# xcodegen, the package resolution, xcodebuild or its build phases.
ed_key=${SPARKLE_ED_PRIVATE_KEY:-}
unset SPARKLE_ED_PRIVATE_KEY
cd "$(dirname "$0")/.."

version=${1:-}
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: bash scripts/release.sh <version>   (for example 0.0.1)" >&2
  exit 2
fi
identity=${SIGN_IDENTITY:-Toma Project Signing}
# An ad hoc build only tries the pipeline: its app, DMG and appcast never reach the release history in dist/.
if [[ $identity == - ]]; then out=build/adhoc-dist; else out=dist; fi
download_prefix=${DOWNLOAD_PREFIX:-http://localhost:8000/}
[[ $download_prefix == */ ]] || download_prefix+=/
build_number=$(git rev-list --count HEAD)

app=Toma
archive=build/$app.xcarchive
bundle=$out/$app.app
dmg=$out/$app-$version.dmg
dmg_check=build/dmg-check
appcast_work=build/appcast-staging
sparkle_bin=build/SourcePackages/artifacts/sparkle/Sparkle/bin
# Only the pinned versions; netrc: resolving never waits on a keychain prompt for github.com credentials.
package_flags=(-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -packageAuthorizationProvider netrc)
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
# Each version is one build: Sparkle tells versions apart by the build number, and both would share one DMG name.
if [[ -f $out/appcast.xml ]]; then
  other_builds=$(xmllint --xpath "count(//item[*[local-name()='shortVersionString']='$version'][*[local-name()='version']!='$build_number'])" "$out/appcast.xml")
  [[ $other_builds == 0 ]] ||
    fail "$out/appcast.xml already has $app $version from another build: release this one as a new version"
fi
git diff --quiet HEAD -- || echo "release: warning: the working tree has uncommitted changes; they are in this build" >&2

step "Resolving the pinned packages and checking their licenses"
xcodegen generate
xcodebuild -resolvePackageDependencies -project Toma.xcodeproj -scheme Toma -derivedDataPath build "${package_flags[@]}"
bash scripts/check-licenses.sh

step "Archiving $app $version (build $build_number), signed by \"$identity\""
# Only what this run makes again: earlier DMGs and the appcast in $out/ stay.
rm -rf "$archive" "$bundle" "$dmg"
mkdir -p "$out"
source_setting=()
if [[ -n ${SOURCE_CODE_URL:-} ]]; then source_setting=(SOURCE_CODE_URL="$SOURCE_CODE_URL"); fi
# Apple silicon only (spec §12). project.yml says so for the app's target, but the packages' targets take
# their architectures from this command line: without ARCHS they build for Intel too, where Float16 doesn't exist.
xcodebuild archive -quiet -project Toma.xcodeproj -scheme Toma -configuration Release -derivedDataPath build \
  -archivePath "$archive" -destination 'generic/platform=macOS' "${package_flags[@]}" ARCHS=arm64 \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" ${source_setting[@]+"${source_setting[@]}"}
ditto "$archive/Products/Applications/$app.app" "$bundle"
# GPLv3 §4 and §6: the object code goes out with the license and the notice.
[[ -f $bundle/Contents/Resources/LICENSE ]] || fail "$bundle has no Contents/Resources/LICENSE"

step "Signing Sparkle's helpers, toma and the app with \"$identity\""
# Signing outside Xcode's export, as Sparkle documents it: every helper with the app's identity, from the
# inside out, never --deep. Xcode re-signed Sparkle.framework only; its helpers kept Sparkle's ad hoc
# signatures. The app isn't sandboxed and enables none of Sparkle's XPC services, so they are left out.
# The toma command line (Contents/Helpers/toma, scripts/embed-toma.sh) is signed again the same way.
sparkle=$bundle/Contents/Frameworks/Sparkle.framework
sparkle_version=$sparkle/Versions/$(readlink "$sparkle/Versions/Current")
toma=$bundle/Contents/Helpers/toma
[[ -x $toma ]] || fail "$bundle has no Contents/Helpers/toma"
rm -rf "$sparkle_version/XPCServices" "$sparkle/XPCServices"
signed=("$sparkle_version/Autoupdate" "$sparkle_version/Updater.app" "$sparkle" "$toma" "$bundle")
# No secure timestamp: Apple's timestamp server may refuse identities it didn't issue, and a self-signed
# certificate gains nothing from one.
sign() { codesign --force --sign "$identity" --options runtime --timestamp=none "$@"; }
sign "$sparkle_version/Autoupdate"
sign "$sparkle_version/Updater.app"
sign "$sparkle"
sign --identifier dev.toma.Toma.toma "$toma"
sign --entitlements App/Toma.entitlements "$bundle"

step "Checking the signatures"
codesign --verify --deep --strict "$bundle"
echo "codesign --verify --deep --strict: valid"
[[ ! -e $sparkle_version/XPCServices && ! -L $sparkle/XPCServices ]] || fail "Sparkle's XPC services are still in the app"
for path in "${signed[@]}"; do
  info=$(codesign -dv --verbose=4 "$path" 2>&1)
  flags=$(sed -n 's/^CodeDirectory .*\(flags=[^ ]*\).*/\1/p' <<<"$info")
  [[ $flags == *runtime* ]] || fail "$path: the hardened runtime is off ($flags)"
  if [[ $identity != - ]]; then
    grep -qxF "Authority=$identity" <<<"$info" || fail "$path is not signed by \"$identity\""
  fi
  echo "${path#"$out"/}: $flags$(grep -m1 '^Authority=' <<<"$info" | sed 's/^/, /')"
done
details=$(codesign -dv --verbose=4 "$bundle" 2>&1)
grep -E '^(Identifier|Authority|TeamIdentifier|Signature)=' <<<"$details"
requirement=$(codesign -d -r- "$bundle" 2>&1 | grep 'designated =>')
echo "$requirement"
if [[ $identity != - && $requirement != *'certificate leaf = H"'* ]]; then
  fail "the designated requirement doesn't name the certificate: macOS would not see the same app after an update"
fi
entitlements=$(codesign -d --entitlements - "$bundle" 2>/dev/null)
grep -q 'com.apple.security.cs.disable-library-validation' <<<"$entitlements" ||
  fail "com.apple.security.cs.disable-library-validation is missing: without a Team ID, dyld rejects Sparkle.framework"
if grep -q 'com.apple.security.get-task-allow' <<<"$entitlements"; then
  fail "com.apple.security.get-task-allow is present: a release must not be debuggable"
fi
echo "entitlements: disable-library-validation present, get-task-allow absent"

[[ $(plist CFBundleShortVersionString) == "$version" ]] || fail "CFBundleShortVersionString is $(plist CFBundleShortVersionString), not $version"
[[ $(plist CFBundleVersion) == "$build_number" ]] || fail "CFBundleVersion is $(plist CFBundleVersion), not $build_number"
[[ -n $(plist NSHumanReadableCopyright) ]] || fail "the app has no NSHumanReadableCopyright"
source_url=$(plist SourceCodeURL)
if [[ -z $source_url ]]; then
  echo "release: warning: no SourceCodeURL (set SOURCE_CODE_URL): the app can't say where its source code is," \
    "which GPLv3 asks of a build given to others" >&2
fi
feed_url=$(plist SUFeedURL)
public_key=$(plist SUPublicEDKey)
[[ $feed_url == http*://*/* ]] || fail "SUFeedURL is \"$feed_url\" (in Config/Identity.xcconfig, write each // as /\$()/)"
echo "version $version, build $build_number, feed $feed_url, EdDSA public key ${public_key:-(none: updates are off in this build)}, source ${source_url:-(none)}"

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
# The designed window (background, icons in place, LICENSE hidden): scripts/make-dmg.sh asks Finder to lay it out.
bash scripts/make-dmg.sh "$bundle" "$version" "$dmg"
hdiutil verify -quiet "$dmg"
echo "hdiutil verify: checksum valid"
rm -rf "$dmg_check"
mkdir -p "$dmg_check"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$dmg_check" "$dmg"
dmg_license=yes
[[ -f $dmg_check/LICENSE && -f $dmg_check/$app.app/Contents/Resources/LICENSE ]] || dmg_license=
dmg_window=yes
[[ -f $dmg_check/.DS_Store && -f $dmg_check/.background/background.tiff ]] || dmg_window=
hdiutil detach -quiet "$dmg_check"
rmdir "$dmg_check"
[[ -n $dmg_license ]] || fail "$dmg has no LICENSE next to the app, or the app in it has none"
[[ -n $dmg_window ]] || fail "$dmg has no window layout (.DS_Store) or no background"
echo "$dmg: LICENSE next to the app (hidden) and inside it; window layout and background in place"

step "Appcast"
if [[ -n $ed_key ]]; then
  key_source="SPARKLE_ED_PRIVATE_KEY"
elif [[ $identity == - ]]; then
  # Never the real key for an ad hoc build: its appcast would put an ad hoc build in a feed signed for real.
  echo "Ad hoc build without SPARKLE_ED_PRIVATE_KEY: no appcast (the login keychain's key is never used for one)."
  key_source=
elif security find-generic-password -s "$keychain_service" -a ed25519 >/dev/null 2>&1; then
  key_source="the login keychain"
else
  echo "No EdDSA private key (neither SPARKLE_ED_PRIVATE_KEY nor Sparkle's key in the login keychain):"
  echo "skipping $out/appcast.xml. See docs/release.md for creating the key."
  key_source=
fi
if [[ -n $key_source ]]; then
  [[ -n $public_key ]] || fail "there is a private key but the app has no SUPublicEDKey: set SPARKLE_PUBLIC_KEY in Config/Identity.xcconfig"
  echo "Signing with the key from $key_source; downloads from $download_prefix"
  # generate_appcast rewrites the appcast, writes deltas and moves old files in the folder it is given: it
  # works on a copy, and $out/ takes the result only if every check passes, so a failed run leaves the
  # history as it was.
  shopt -s nullglob
  rm -rf "$appcast_work"
  mkdir -p "$appcast_work"
  for file in "$out"/*.dmg "$out"/*.delta "$out"/appcast.xml; do
    if [[ -e $file ]]; then cp -p "$file" "$appcast_work/"; fi
  done
  status=0
  if [[ -n $ed_key ]]; then
    output=$(printf '%s' "$ed_key" |
      "$sparkle_bin/generate_appcast" --ed-key-file - --download-url-prefix "$download_prefix" "$appcast_work" 2>&1) || status=$?
  else
    output=$("$sparkle_bin/generate_appcast" --download-url-prefix "$download_prefix" "$appcast_work" 2>&1) || status=$?
  fi
  echo "$output"
  ((status == 0)) || fail "generate_appcast failed (exit $status); $out/ is unchanged"
  # generate_appcast only warns when the key doesn't match the app's, and writes an unsigned item; or when two
  # versions are signed differently, which an update would reject or pay for with the permissions. Ad hoc
  # signatures differ from one build to the next, so that one is expected then.
  problems=$(grep -iE '^(warning|error)' <<<"$output" || true)
  if [[ $identity == - ]]; then
    problems=$(grep -v '^Warning: found mismatch code signing identity' <<<"$problems" || true)
  fi
  [[ -z $problems ]] || fail "generate_appcast reported a problem (above); $out/ is unchanged"
  [[ -f $appcast_work/appcast.xml ]] || fail "generate_appcast wrote no appcast.xml; $out/ is unchanged"
  enclosure=$(grep -F "url=\"$download_prefix$app-$version.dmg\"" "$appcast_work/appcast.xml") ||
    fail "the appcast does not point to $download_prefix$app-$version.dmg; $out/ is unchanged"
  [[ $enclosure == *'sparkle:edSignature='* ]] || fail "the appcast has no EdDSA signature for $app $version; $out/ is unchanged"
  rm -f "$out"/*.dmg "$out"/*.delta "$out"/appcast.xml
  old_updates=("$appcast_work"/old_updates/*)
  if ((${#old_updates[@]} > 0)); then
    mkdir -p "$out/old_updates"
    mv "${old_updates[@]}" "$out/old_updates/"
  fi
  mv "$appcast_work"/*.dmg "$appcast_work"/*.delta "$appcast_work"/appcast.xml "$out/"
  rm -rf "$appcast_work"
  shopt -u nullglob
  echo "$out/appcast.xml: $(grep -c '<item>' "$out/appcast.xml") versions"
fi

step "Done"
ls -l "$out"
