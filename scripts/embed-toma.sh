#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build phase of the app (see project.yml): puts the toma command line in Contents/Helpers/toma and signs it as the
# app is signed, with the hardened runtime, before Xcode signs the app around it (fases 4 y 5 design §6.2, plan 4b
# decision 21). The target depends on the RecorderKit package's toma product without linking it, so Xcode builds it
# into $BUILT_PRODUCTS_DIR. Settings ▸ General ▸ Install Command Line Tool links it from the PATH. Run by Xcode, which
# sets the variables used here.
set -euo pipefail

source="$BUILT_PRODUCTS_DIR/toma"
if [ ! -x "$source" ]; then
  echo "error: $source was not built: the Toma target depends on RecorderKit's toma product (project.yml)" >&2
  exit 1
fi
helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$helpers"
rm -f "$helpers/toma"
cp "$source" "$helpers/toma"
if [ "${CODE_SIGNING_ALLOWED:-YES}" = YES ]; then
  # The identity Xcode signs the app with ("-", ad hoc, to run locally).
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --identifier "$PRODUCT_BUNDLE_IDENTIFIER.toma" --options runtime \
    --timestamp=none "$helpers/toma"
fi
