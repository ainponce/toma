# SPDX-License-Identifier: GPL-3.0-or-later
VERSION ?=

.PHONY: project test tsan crash-test build install release

project:
	xcodegen generate

test:
	swift test --package-path Packages/RecorderKit

# The thread-safety argument of TrackPipeline, TrackFrameReader and the take's life cycle rests on this run (plan
# exit criterion). Suites that do not exist yet match nothing; each task that adds one is covered from then on.
tsan:
	TSAN_OPTIONS=$${TSAN_OPTIONS:-halt_on_error=1} swift test --package-path Packages/RecorderKit --sanitize=thread \
		--filter 'RecordingCoordinatorTests|TrackFrameReaderTests|RecordingControllerTests|QuitSequencerTests|CameraTests|SystemAudioTests|WindowCaptureTests|LevelMeterTests|CountdownTests'

crash-test:
	bash scripts/test-crash-recovery.sh

# Debug signs with the project's identity when this Mac has it (scripts/create-signing-cert.sh, the owner's keychain),
# so macOS keeps the app's permissions across rebuilds; without it, ad hoc.
DEBUG_SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -qF '"Toma Project Signing"' && echo 'Toma Project Signing')

# Toma.xcodeproj is generated (only its Package.resolved is in git): a fresh clone builds in one command.
build: project
	xcodebuild -project Toma.xcodeproj -scheme Toma -configuration Debug -derivedDataPath build build \
		$(if $(DEBUG_SIGN_IDENTITY),CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$(DEBUG_SIGN_IDENTITY)")

install: project
	xcodebuild -project Toma.xcodeproj -scheme Toma -configuration Release -derivedDataPath build build
	rm -rf /Applications/Toma.app
	ditto build/Build/Products/Release/Toma.app /Applications/Toma.app

release:
	bash scripts/release.sh $(VERSION)
