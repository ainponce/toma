# SPDX-License-Identifier: GPL-3.0-or-later
VERSION ?=

.PHONY: project test tsan crash-test build install release

project:
	xcodegen generate

test:
	swift test --package-path Packages/RecorderKit

# The thread-safety argument of TrackPipeline and TrackFrameReader rests on this run (plan exit criterion).
tsan:
	TSAN_OPTIONS=$${TSAN_OPTIONS:-halt_on_error=1} swift test --package-path Packages/RecorderKit --sanitize=thread \
		--filter 'RecordingCoordinatorTests|TrackFrameReaderTests'

crash-test:
	bash scripts/test-crash-recovery.sh

# Toma.xcodeproj is generated (only its Package.resolved is in git): a fresh clone builds in one command.
build: project
	xcodebuild -project Toma.xcodeproj -scheme Toma -configuration Debug -derivedDataPath build build

install: project
	xcodebuild -project Toma.xcodeproj -scheme Toma -configuration Release -derivedDataPath build build
	rm -rf /Applications/Toma.app
	ditto build/Build/Products/Release/Toma.app /Applications/Toma.app

release:
	bash scripts/release.sh $(VERSION)
