#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds Toma's DMG with its designed window: the background from scripts/make-dmg-background.swift, Toma and a link to
# /Applications where the picture expects them, no toolbar, and the LICENSE inside but hidden (the app carries it too).
#   bash scripts/make-dmg.sh <Toma.app> <version> <output.dmg>
# Finder writes the window's look into the DMG (.DS_Store), so the script asks Finder through AppleScript: the first time,
# macOS asks to let the app that runs it (Terminal, Claude) control Finder. scripts/release.sh calls this.
set -euo pipefail

app_path=${1:-}
version=${2:-}
output=${3:-}
[[ -d $app_path && -n $version && -n $output ]] || { echo "usage: bash scripts/make-dmg.sh <Toma.app> <version> <output.dmg>" >&2; exit 2; }
fail() { echo "make-dmg: $*" >&2; exit 1; }

cd "$(dirname "$0")/.."
app_name=$(basename "$app_path" .app)
volume="$app_name $version"
work=build/dmg-work
staging=$work/staging
image=$work/rw.dmg

[[ -e /Volumes/$volume ]] && fail "a volume named \"$volume\" is already mounted: eject it first"

rm -rf "$work"
mkdir -p "$staging/.background"
eval "$(swift scripts/make-dmg-background.swift --layout)"
swift scripts/make-dmg-background.swift "$staging/.background/background.tiff" >/dev/null
ditto "$app_path" "$staging/$app_name.app"
cp LICENSE "$staging/LICENSE"
ln -s /Applications "$staging/Applications"

# A writable image with room for Finder's .DS_Store, then the window's look, then the compressed image.
size_mb=$(( $(du -sm "$staging" | cut -f1) + 20 ))
hdiutil create -quiet -volname "$volume" -srcfolder "$staging" -fs HFS+ -format UDRW -size "${size_mb}m" -ov "$image"
device=$(hdiutil attach -readwrite -noverify -noautoopen "$image" | awk '/Apple_HFS/ {print $1; exit}')
[[ -n $device ]] || fail "could not attach $image"
mount="/Volumes/$volume"
detach() { hdiutil detach -quiet "$device" 2>/dev/null || hdiutil detach -quiet -force "$device" 2>/dev/null || true; }
trap detach EXIT
[[ -d $mount ]] || fail "$image did not mount at $mount"
chflags hidden "$mount/LICENSE"
# Finder sees a new volume a moment after it mounts.
for _ in $(seq 1 20); do
  [[ $(osascript -e "tell application \"Finder\" to exists disk \"$volume\"" 2>/dev/null) == true ]] && break
  sleep 0.5
done

title_bar=28
if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$volume"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, $((200 + width)), $((120 + height + title_bar))}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to $icon_size
    set text size of viewOptions to $text_size
    set shows item info of viewOptions to false
    set shows icon preview of viewOptions to false
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "$app_name.app" of container window to {$toma_x, $toma_y}
    set position of item "Applications" of container window to {$applications_x, $applications_y}
    -- Hidden items, out of sight below the window for Macs that show hidden files.
    try
      set position of item ".background" of container window to {$((width / 2 - 60)), $((height + 160))}
    end try
    try
      set position of item "LICENSE" of container window to {$((width / 2 + 60)), $((height + 160))}
    end try
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
then
  fail "Finder could not lay out the window. If macOS denied it, allow it in System Settings › Privacy & Security › Automation (the app that ran this → Finder) and run again"
fi

[[ -f $mount/.DS_Store ]] || fail "Finder wrote no .DS_Store: the window would open without its look"
rm -rf "$mount/.fseventsd"
sync
detach
trap - EXIT

hdiutil convert -quiet "$image" -format UDZO -imagekey zlib-level=9 -ov -o "$output"
rm -rf "$work"
echo "$output: window ${width}×${height}, background, Toma and Applications placed, LICENSE hidden"
