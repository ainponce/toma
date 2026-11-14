#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build phase of the app (see project.yml). String catalogs do not expand build settings, so the
# InfoPlist.strings compiled from App/Resources/InfoPlist.xcstrings still say "$(PRODUCT_NAME)". This
# puts the product name in, keys included: a document type's name is localized under its expanded
# Info.plist value. Run by Xcode, which sets the variables used here.
set -euo pipefail

resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
for strings in "$resources"/*.lproj/InfoPlist.strings; do
  [ -e "$strings" ] || continue
  json=$(plutil -convert json -o - "$strings")
  printf '%s' "${json//\$(PRODUCT_NAME)/$PRODUCT_NAME}" | plutil -convert binary1 -o "$strings" -
done
