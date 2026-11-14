# SPDX-License-Identifier: GPL-3.0-or-later
VERSION ?=

.PHONY: project test crash-test build install release

project:
	xcodegen generate

test:
	swift test --package-path Packages/RecorderKit

crash-test:
	bash scripts/test-crash-recovery.sh

build:
	xcodebuild -project Toma.xcodeproj -scheme Toma -configuration Debug -derivedDataPath build build

install:
	xcodebuild -project Toma.xcodeproj -scheme Toma -configuration Release -derivedDataPath build build
	rm -rf /Applications/Toma.app
	ditto build/Build/Products/Release/Toma.app /Applications/Toma.app

release:
	bash scripts/release.sh $(VERSION)
