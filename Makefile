# SPDX-License-Identifier: GPL-3.0-or-later
VERSION ?=

.PHONY: project test tsan crash-test golden golden-record build install release

project:
	xcodegen generate

test:
	swift test --package-path Packages/RecorderKit

# The thread-safety argument of TrackPipeline, TrackFrameReader, the take's life cycle, the process's cache of
# background images, a renderer's cursor images and the preview's audio rests on this run (plan exit criterion). Every
# name matches tests: a suite, or a file of loose @Test functions (TrackFrameReaderTests, InputActivityRecorderTests,
# BackgroundImageTests, CursorRenderTests, AudioRingBufferTests, PreviewAudioPlayerTests).
tsan:
	TSAN_OPTIONS=$${TSAN_OPTIONS:-halt_on_error=1} swift test --package-path Packages/RecorderKit --sanitize=thread \
		--filter 'RecordingCoordinatorTests|TrackFrameReaderTests|RecordingControllerTests|QuitSequencerTests|CameraTests|SystemAudioTests|CaptureRunLifecycleTests|WindowCaptureTests|LevelMeterTests|FocusGuardTests|TimeLimitTests|WallpaperLayoutTests|CursorImageRecorderTests|InputActivityRecorderTests|BackgroundImageTests|EditedMixTests|EditJournalTests|EditSessionTests|CursorRenderTests|SpeedStretchTests|AudioRingBufferTests|PreviewAudioPlayerTests|PackageUpgradeTests|ThumbnailCacheTests|WaveformCacheTests|ScreenSamplingTests|AssetImportTests|ScreenChangeTests|GIFQuantizerTests|EditedExportTests|PendingMigrationTests|LibraryStoresTests|PreviewEngineTests|LibraryThumbnailsTests'

crash-test:
	bash scripts/test-crash-recovery.sh

# The golden files of milestone 1b (plan decision 3): the frames and the mix of v1 and v2 projects without edits
# (frames.bin and frames.bin.mix), recorded once from Task 1's commit before any render change, outside git (their bytes
# depend on the GPU, the system's Metal compiler and VideoToolbox), with VERSION, the fingerprint of the system that
# recorded them, and COMMIT, the commit they were recorded from. They live in the main checkout (the parent of git's
# common dir), so every worktree, build/golden-src included, compares against the same files and none records its own.
GOLDEN_ROOT := $(dir $(shell git rev-parse --path-format=absolute --git-common-dir 2>/dev/null))
GOLDEN ?= $(or $(GOLDEN_ROOT),$(CURDIR)/)build/golden-1b/frames.bin
GOLDEN_FILE = $(abspath $(GOLDEN))
GOLDEN_DIR = $(patsubst %/,%,$(dir $(GOLDEN_FILE)))
GOLDEN_SRC = $(or $(GOLDEN_ROOT),$(CURDIR)/)build/golden-src
GOLDEN_TESTS = swift test --package-path Packages/RecorderKit --filter 'goldenFramesMatch|goldenMixMatches'
# Sets $$commit to the commit the golden files were recorded from.
GOLDEN_COMMIT = commit=$$(cat "$(GOLDEN_DIR)/COMMIT" 2>/dev/null || echo "<Task 1's last commit>")
# Records them from $$commit, in a worktree of that commit.
GOLDEN_RECORD_AGAIN = git worktree add '$(GOLDEN_SRC)' $$commit && make -C '$(GOLDEN_SRC)' golden-record GOLDEN='$(GOLDEN_FILE)' \
	&& git worktree remove '$(GOLDEN_SRC)'
# Whether both golden tests ran and passed, from the output of GOLDEN_TESTS in file $(1): a filter that matches no test
# exits with 0 too.
GOLDEN_RAN = { grep -qF 'goldenFramesMatch() passed' "$(1)" && grep -qF 'goldenMixMatches() passed' "$(1)" \
	|| { echo "goldenFramesMatch and goldenMixMatches did not both run and pass: nothing was compared" >&2; false; }; }

golden golden-record: SHELL := /bin/bash

golden:
	@$(GOLDEN_COMMIT); \
	if [ ! -f "$(GOLDEN_FILE)" ] || [ ! -f "$(GOLDEN_FILE).mix" ]; then \
		echo "no golden files at $(GOLDEN_FILE) and $(GOLDEN_FILE).mix: record them from Task 1's commit, never from later code (plan decision 3):" >&2; \
		echo "  $(GOLDEN_RECORD_AGAIN)" >&2; \
		exit 1; \
	fi; \
	if [ ! -f "$(GOLDEN_DIR)/VERSION" ]; then \
		echo "no $(GOLDEN_DIR)/VERSION, the fingerprint of the system the golden files were recorded on: they cannot be compared without it; record them again from $$commit, never from later code (plan decision 3):" >&2; \
		echo "  mv '$(GOLDEN_DIR)' '$(GOLDEN_DIR).old' && $(GOLDEN_RECORD_AGAIN)" >&2; \
		exit 1; \
	fi; \
	now=$$(mktemp -t toma-golden); \
	bash scripts/golden-system.sh > "$$now" || { rm -f "$$now"; echo "scripts/golden-system.sh failed: no fingerprint of this system to compare" >&2; exit 1; }; \
	if ! cmp -s "$(GOLDEN_DIR)/VERSION" "$$now"; then \
		echo "the system changed since the golden files in $(GOLDEN_DIR) were recorded (< then, > now):" >&2; \
		diff "$(GOLDEN_DIR)/VERSION" "$$now" >&2; \
		rm -f "$$now"; \
		echo "record them again from the commit they were recorded from, $$commit, never from later code (plan decision 3):" >&2; \
		echo "  mv '$(GOLDEN_DIR)' '$(GOLDEN_DIR).old' && $(GOLDEN_RECORD_AGAIN)" >&2; \
		exit 1; \
	fi; \
	rm -f "$$now"
	@set -o pipefail; log=$$(mktemp -t toma-golden); \
	TOMA_GOLDEN_FILE="$(GOLDEN_FILE)" $(GOLDEN_TESTS) 2>&1 | tee "$$log" && $(call GOLDEN_RAN,$$log); \
	status=$$?; rm -f "$$log"; exit $$status

# Records into $(GOLDEN_DIR).partial and moves that into place only once both tests passed and VERSION and COMMIT are
# written: the golden files are there whole or not at all.
golden-record:
	@$(GOLDEN_COMMIT); \
	if [ -e "$(GOLDEN_DIR)" ]; then \
		echo "$(GOLDEN_DIR) is already there: the golden files are recorded once, from Task 1's commit, never over others (plan decision 3)." >&2; \
		echo "To record them again from the commit they were recorded from ($$commit): mv '$(GOLDEN_DIR)' '$(GOLDEN_DIR).old' && $(GOLDEN_RECORD_AGAIN)" >&2; \
		exit 1; \
	fi
	@test -z "$$(git status --porcelain)" || { echo "this checkout has uncommitted changes: the golden files are recorded from a commit, which they name in COMMIT" >&2; exit 1; }
	@set -o pipefail; log=$$(mktemp -t toma-golden); \
	rm -rf "$(GOLDEN_DIR).partial" && mkdir -p "$(GOLDEN_DIR).partial" && \
	TOMA_GOLDEN_FILE="$(GOLDEN_DIR).partial/$(notdir $(GOLDEN_FILE))" TOMA_GOLDEN_RECORD=1 $(GOLDEN_TESTS) 2>&1 | tee "$$log" && \
	$(call GOLDEN_RAN,$$log) && \
	bash scripts/golden-system.sh > "$(GOLDEN_DIR).partial/VERSION" && git rev-parse HEAD > "$(GOLDEN_DIR).partial/COMMIT" && \
	test ! -e "$(GOLDEN_DIR)" && mv "$(GOLDEN_DIR).partial" "$(GOLDEN_DIR)"; \
	status=$$?; rm -f "$$log"; \
	if [ $$status -eq 0 ]; then \
		echo "recorded $(GOLDEN_DIR) from $$(cat "$(GOLDEN_DIR)/COMMIT")"; \
	else \
		rm -rf "$(GOLDEN_DIR).partial"; echo "nothing recorded in $(GOLDEN_DIR)" >&2; \
	fi; \
	exit $$status

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
