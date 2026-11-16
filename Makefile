# SPDX-License-Identifier: GPL-3.0-or-later
VERSION ?=

.PHONY: project test tsan crash-test golden golden-record build install release

project:
	xcodegen generate

test:
	swift test --package-path Packages/RecorderKit

# The thread-safety argument of TrackPipeline, TrackFrameReader and the take's life cycle rests on this run (plan
# exit criterion). Every name matches tests: a suite, or the file of loose @Test functions (TrackFrameReaderTests).
tsan:
	TSAN_OPTIONS=$${TSAN_OPTIONS:-halt_on_error=1} swift test --package-path Packages/RecorderKit --sanitize=thread \
		--filter 'RecordingCoordinatorTests|TrackFrameReaderTests|RecordingControllerTests|QuitSequencerTests|CameraTests|SystemAudioTests|CaptureRunLifecycleTests|WindowCaptureTests|LevelMeterTests|FocusGuardTests|TimeLimitTests|WallpaperLayoutTests'

crash-test:
	bash scripts/test-crash-recovery.sh

# The golden files of milestone 1b (plan decision 3): the frames and the mix of v1 and v2 projects without edits,
# recorded from Task 1's commit before any render change, outside git (their bytes depend on the GPU, the system's
# Metal compiler and VideoToolbox), with VERSION, the fingerprint of the system that recorded them, next to them.
GOLDEN ?= build/golden-1b/frames.bin
GOLDEN_TESTS = swift test --package-path Packages/RecorderKit --filter 'goldenFramesMatch|goldenMixMatches'

golden:
	@bash scripts/golden-system.sh | cmp -s - "$(dir $(GOLDEN))VERSION" || { \
		echo "the system changed since the golden files were recorded: record them again from Task 1's commit (git worktree add build/golden-src <sha>, then make golden-record there), never from later code" >&2; \
		exit 1; }
	TOMA_GOLDEN_FILE="$(abspath $(GOLDEN))" $(GOLDEN_TESTS)

golden-record:
	mkdir -p "$(dir $(GOLDEN))"
	TOMA_GOLDEN_FILE="$(abspath $(GOLDEN))" TOMA_GOLDEN_RECORD=1 $(GOLDEN_TESTS)
	bash scripts/golden-system.sh > "$(dir $(GOLDEN))VERSION"

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
