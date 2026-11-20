# SPDX-License-Identifier: GPL-3.0-or-later
VERSION ?=

.PHONY: project test tsan crash-test golden golden-record golden-fixtures golden-accept build install release golden-1c golden-1c-record \
	golden-2 golden-2-record golden-3 golden-3-record golden-4 golden-4-record

project:
	xcodegen generate

test:
	swift test --package-path Packages/RecorderKit

# The thread-safety argument of TrackPipeline, TrackFrameReader, the take's life cycle, the process's cache of
# background images, a renderer's cursor images, the preview's audio, the default style's store, the preparation of a
# preview, the synthetic input, the cancellation of an export, the steps of quitting with editors open (and while the
# library copies), a log that starts again behind the Undo menu, and 1c's library, styles, GIF and card camera rests on
# this run (plan exit criterion). Every name matches tests: a suite, a file of loose @Test functions
# (TrackFrameReaderTests, InputActivityRecorderTests, BackgroundImageTests, CursorRenderTests, AudioRingBufferTests,
# PreviewAudioPlayerTests, DefaultStyleStoreTests, ScreenlessPreviewTests, LogRestartMenuTests), or one test
# (cancelledExportCleansUp, the only cancellation of the pipelined export; theCardsCameraComesAndGoes, the card's and
# the stage's cameras built at once).
tsan:
	TSAN_OPTIONS=$${TSAN_OPTIONS:-halt_on_error=1} swift test --package-path Packages/RecorderKit --sanitize=thread \
		--filter 'RecordingCoordinatorTests|TrackFrameReaderTests|RecordingControllerTests|QuitSequencerTests|CameraTests|SystemAudioTests|CaptureRunLifecycleTests|WindowCaptureTests|LevelMeterTests|FocusGuardTests|TimeLimitTests|WallpaperLayoutTests|CursorImageRecorderTests|InputActivityRecorderTests|BackgroundImageTests|EditedMixTests|EditJournalTests|EditSessionTests|CursorRenderTests|SpeedStretchTests|AudioRingBufferTests|PreviewAudioPlayerTests|PackageUpgradeTests|ThumbnailCacheTests|WaveformCacheTests|ScreenSamplingTests|AssetImportTests|ScreenChangeTests|GIFQuantizerTests|EditedExportTests|PendingMigrationTests|LibraryStoresTests|PreviewEngineTests|StyleLibraryTests|ApplyStyleTests|LibraryOperationsTests|LibraryScannerTests|LibraryWatcherTests|LibraryThumbnailsTests|ReadDocumentWithoutEventsTests|theCardsCameraComesAndGoes|WindowFrameTests|GIFExporterTests|GIFEstimateTests|LibraryActionRunnerTests|LibraryWorkTests|DefaultStyleStoreTests|PreviewPreparationTests|ScreenlessPreviewTests|SyntheticSourcesTests|cancelledExportCleansUp|QuitWithEditorsTests|LogRestartMenuTests|QuitWithEditorsAndCopiesTests|hiddenScreenIsNotDecoded|trackNeededAfterABorderIsDecodedAhead|previewSnapshotEqualsTheExportFrameWithLayouts|ProjectJobsTests|KeyPressRecorderTests|RecordingFormat4Tests|ScriptedKeyEventsTests|LUTImportTests|ExternalDeviceTests|TranscriberTests|SpeechModelTests|CleanMixTests|SoundIsolationTests|PersonMaskEngineTests|FaceTrackEngineTests|CameraAnalysisTests|SensitiveScanJobTests|maskIsDecodedAhead|VoiceJobsTests|wordTexturesAreDrawnAhead|previewEqualsExportWithCaptions|DecodingSlotsTests|LoadedProjectTakesTests|SequenceAnalysesTests|CalmZoomPathTests|SystemAudioTracksTests|RerecordControllerTests|SpeechAmountTests|TranscriberTrackTests|drawingTwiceGivesTheSameBytes|LiveMicrophoneFeedTests|MeteredSourceListenTests|LiveAnalysisTests|MusicAnalysisTests|ImportedAudioTests|cardTexturesAreDrawnAhead|previewEqualsExportWithACard|measuresAreSharedAcrossThreads|AudioFileWaveformTests|MediaAudioTests|aFileGoneBeforeTheMixOpensItIsMadeAgain|annotationBitmapsAreDrawnAhead|visibleBitmapsAreNeverDropped|previewEqualsExportWithAnnotations|TeleprompterLinesTests|TeleprompterTests|MediaClipRenderTests|OverlayMediaRenderTests|OtherTakesReleaseTests|PreviewEngineAlphaTests|S3ClientTests|ShareHistoryTests|AccessibilityFocusRecorderTests|AXFocusSourceTests|SyntheticFocusRecorderTests|ShareServiceTests|ShareJobTests'

crash-test:
	bash scripts/test-crash-recovery.sh

# The golden files of milestone 1b (plan decision 3): the frames and the mix of v1 and v2 projects without edits
# (frames.bin and frames.bin.mix), recorded once from Task 1's commit before any render change, outside git (their bytes
# depend on the GPU, the system's Metal compiler and VideoToolbox), with VERSION, the fingerprint of the system that
# recorded them, and COMMIT, the commit they were recorded from. They live in the main checkout (the parent of git's
# common dir), so every worktree, build/golden-src included, compares against the same files and none records its own.
# Next to them, fixtures.sha holds the digests of the cases' video as this code's hardware encoder writes it (make
# golden-fixtures, once, from a run whose frames matched): with them, goldenFramesMatch tells a change of the render
# from other video of the encoder, and writes the cases again only for the latter.
GOLDEN_ROOT := $(dir $(shell git rev-parse --path-format=absolute --git-common-dir 2>/dev/null))
GOLDEN ?= $(or $(GOLDEN_ROOT),$(CURDIR)/)build/golden-1b/frames.bin
GOLDEN_FILE = $(abspath $(GOLDEN))
GOLDEN_DIR = $(patsubst %/,%,$(dir $(GOLDEN_FILE)))
GOLDEN_SRC = $(or $(GOLDEN_ROOT),$(CURDIR)/)build/golden-src
GOLDEN_FIXTURES = $(GOLDEN_DIR)/fixtures.sha
# 1 to have goldenFramesMatch write fixtures.sha (make golden-fixtures).
GOLDEN_FIXTURES_RECORD ?=
GOLDEN_TESTS = swift test --package-path Packages/RecorderKit --filter 'goldenFramesMatch|goldenMixMatches'
# Sets $$commit to the commit the golden files were recorded from.
GOLDEN_COMMIT = commit=$$(cat "$(GOLDEN_DIR)/COMMIT" 2>/dev/null || echo "<Task 1's last commit>")
# Records them from $$commit, in a worktree of that commit, then checks them with this code (golden-accept). Record them
# with the Mac doing no other video work: $$commit writes the cases' video with any encoder, so files recorded while the
# media engine was busy would hold frames of the software encoder's video.
GOLDEN_RECORD_AGAIN = git worktree add '$(GOLDEN_SRC)' $$commit && make -C '$(GOLDEN_SRC)' golden-record GOLDEN='$(GOLDEN_FILE)' \
	&& git worktree remove '$(GOLDEN_SRC)' && make golden-accept GOLDEN='$(GOLDEN_FILE)'
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
	TOMA_GOLDEN_FILE="$(GOLDEN_FILE)" TOMA_GOLDEN_FIXTURES="$(GOLDEN_FIXTURES)" TOMA_GOLDEN_FIXTURES_RECORD="$(GOLDEN_FIXTURES_RECORD)" \
		$(GOLDEN_TESTS) 2>&1 | tee "$$log" && $(call GOLDEN_RAN,$$log); \
	status=$$?; rm -f "$$log"; exit $$status

# Records fixtures.sha next to the golden files from a run of make golden whose frames matched them, never over one.
golden-fixtures:
	@test ! -e "$(GOLDEN_FIXTURES)" || { echo "$(GOLDEN_FIXTURES) is already there: the digests are recorded once, never over others" >&2; exit 1; }
	@$(MAKE) --no-print-directory golden GOLDEN='$(GOLDEN_FILE)' GOLDEN_FIXTURES_RECORD=1
	@test -f "$(GOLDEN_FIXTURES)" || { echo "nothing recorded in $(GOLDEN_FIXTURES)" >&2; exit 1; }

# Checks golden files just recorded from Task 1's commit with this code, three times, and records their fixtures.sha.
# That commit writes the cases' video with any encoder: files it recorded while the media engine took no more hardware
# sessions hold frames of the software encoder's video, which this code's cases (the hardware encoder's video alone)
# never draw, so every later run would fail. Such files are moved aside, to be recorded again with the Mac doing no other
# video work.
golden-accept:
	@for run in 1 2 3; do \
		$(MAKE) --no-print-directory golden GOLDEN='$(GOLDEN_FILE)' || { \
			aside="$(GOLDEN_DIR).rejected-$$(date +%Y%m%d-%H%M%S)"; mv "$(GOLDEN_DIR)" "$$aside"; \
			echo "the golden files just recorded do not match the frames of this code (run $$run of 3): moved to $$aside;" \
				"record them again with the Mac doing no other video work" >&2; \
			exit 1; \
		}; \
	done
	@$(MAKE) --no-print-directory golden-fixtures GOLDEN='$(GOLDEN_FILE)'

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

# The golden files of milestone 1c (plan 1c decision 2): the frames and the mix of the edit documents of 1b
# (documentVersion 1) of GoldenDocuments (frames.bin and frames.bin.mix), with those documents as 1b writes them
# (documents/<case>.json), recorded once from the commit that closes milestone 1b on main, a commit with no change to the
# app's sources (only test code and this Makefile), outside git, with fixtures.sha (the digests of the cases' video the
# frames were drawn from, which tell a change of the render from other video of the encoder), VERSION (the fingerprint
# of scripts/golden-system.sh) and COMMIT (the commit they were recorded from). They live next to 1b's in the main
# checkout. Recording needs EditDocument.currentVersion 1, which no code of 1c has; with 1c's code the same documents,
# migrated, must draw and sound the same. Record them with the Mac doing no other video work.
GOLDEN_1C_DIR ?= $(or $(GOLDEN_ROOT),$(CURDIR)/)build/golden-1c
GOLDEN_1C = $(abspath $(GOLDEN_1C_DIR))
GOLDEN_1C_SRC = $(or $(GOLDEN_ROOT),$(CURDIR)/)build/golden-1c-src
GOLDEN_1C_TESTS = swift test --package-path Packages/RecorderKit --filter 'golden1cFramesMatch|golden1cMixMatches'
# Sets $$commit to the commit the golden files of 1c were recorded from.
GOLDEN_1C_COMMIT = commit=$$(cat "$(GOLDEN_1C)/COMMIT" 2>/dev/null \
	|| echo "<the commit \"test: golden frames and mix of 1b documents, recorded from the commit that closes milestone 1b\">")
# Records them again from $$commit, in a worktree of that commit, with the ones there moved aside.
GOLDEN_1C_RECORD_AGAIN = mv '$(GOLDEN_1C)' '$(GOLDEN_1C).old' && git worktree add '$(GOLDEN_1C_SRC)' $$commit \
	&& make -C '$(GOLDEN_1C_SRC)' golden-1c-record GOLDEN_1C_DIR='$(GOLDEN_1C)' && git worktree remove '$(GOLDEN_1C_SRC)'
# Whether both golden tests of 1c ran and passed, from the output of GOLDEN_1C_TESTS in file $(1): a filter that matches
# no test exits with 0 too.
GOLDEN_1C_RAN = { grep -qF 'golden1cFramesMatch() passed' "$(1)" && grep -qF 'golden1cMixMatches() passed' "$(1)" \
	|| { echo "golden1cFramesMatch and golden1cMixMatches did not both run and pass: nothing was compared" >&2; false; }; }

golden-1c golden-1c-record: SHELL := /bin/bash

golden-1c:
	@$(GOLDEN_1C_COMMIT); \
	for file in frames.bin frames.bin.mix documents fixtures.sha COMMIT; do \
		if [ ! -e "$(GOLDEN_1C)/$$file" ]; then \
			echo "no $(GOLDEN_1C)/$$file: the golden files of 1c are recorded whole, once; record them again from the commit in $(GOLDEN_1C_DIR)/COMMIT, never from later code (plan 1c decision 2):" >&2; \
			echo "  $(GOLDEN_1C_RECORD_AGAIN)" >&2; \
			exit 1; \
		fi; \
	done; \
	if [ ! -f "$(GOLDEN_1C)/VERSION" ]; then \
		echo "no $(GOLDEN_1C)/VERSION, the fingerprint of the system the golden files of 1c were recorded on: they cannot be compared without it; record them again from the commit in $(GOLDEN_1C_DIR)/COMMIT, never from later code (plan 1c decision 2):" >&2; \
		echo "  $(GOLDEN_1C_RECORD_AGAIN)" >&2; \
		exit 1; \
	fi; \
	now=$$(mktemp -t toma-golden-1c); \
	bash scripts/golden-system.sh > "$$now" || { rm -f "$$now"; echo "scripts/golden-system.sh failed: no fingerprint of this system to compare" >&2; exit 1; }; \
	if ! cmp -s "$(GOLDEN_1C)/VERSION" "$$now"; then \
		echo "the system changed since the golden files in $(GOLDEN_1C) were recorded (< then, > now):" >&2; \
		diff "$(GOLDEN_1C)/VERSION" "$$now" >&2; \
		rm -f "$$now"; \
		echo "record them again from the commit in $(GOLDEN_1C_DIR)/COMMIT, never from later code (plan 1c decision 2):" >&2; \
		echo "  $(GOLDEN_1C_RECORD_AGAIN)" >&2; \
		exit 1; \
	fi; \
	rm -f "$$now"
	@set -o pipefail; log=$$(mktemp -t toma-golden-1c); \
	TOMA_GOLDEN_1C_DIR="$(GOLDEN_1C)" $(GOLDEN_1C_TESTS) 2>&1 | tee "$$log" && $(call GOLDEN_1C_RAN,$$log); \
	status=$$?; rm -f "$$log"; exit $$status

# Records into $(GOLDEN_1C).partial and moves that into place only once both tests passed and VERSION and COMMIT are
# written: the golden files of 1c are there whole or not at all.
golden-1c-record:
	@$(GOLDEN_1C_COMMIT); \
	if [ -e "$(GOLDEN_1C)" ]; then \
		echo "$(GOLDEN_1C) is already there: the golden files of 1c are recorded once, from the commit that closes milestone 1b, never over others (plan 1c decision 2)." >&2; \
		echo "To record them again from the commit in $(GOLDEN_1C_DIR)/COMMIT, never from later code (plan 1c decision 2): $(GOLDEN_1C_RECORD_AGAIN)" >&2; \
		exit 1; \
	fi
	@test -z "$$(git status --porcelain)" || { echo "this checkout has uncommitted changes: the golden files of 1c are recorded from a commit, which they name in COMMIT" >&2; exit 1; }
	@set -o pipefail; log=$$(mktemp -t toma-golden-1c); \
	rm -rf "$(GOLDEN_1C).partial" && mkdir -p "$(GOLDEN_1C).partial" && \
	TOMA_GOLDEN_1C_DIR="$(GOLDEN_1C).partial" TOMA_GOLDEN_RECORD=1 $(GOLDEN_1C_TESTS) 2>&1 | tee "$$log" && \
	$(call GOLDEN_1C_RAN,$$log) && \
	bash scripts/golden-system.sh > "$(GOLDEN_1C).partial/VERSION" && git rev-parse HEAD > "$(GOLDEN_1C).partial/COMMIT" && \
	test ! -e "$(GOLDEN_1C)" && mv "$(GOLDEN_1C).partial" "$(GOLDEN_1C)"; \
	status=$$?; rm -f "$$log"; \
	if [ $$status -eq 0 ]; then \
		echo "recorded $(GOLDEN_1C) from $$(cat "$(GOLDEN_1C)/COMMIT")"; \
	else \
		rm -rf "$(GOLDEN_1C).partial"; echo "nothing recorded in $(GOLDEN_1C)" >&2; \
	fi; \
	exit $$status

# The golden files of phase 2 (phase 2 design §14, "golden 2"): the frames and the mix of the edit documents of 1b
# (documentVersion 1) and of 1c (documentVersion 2) of GoldenDocuments (golden2Cases: frames.bin and frames.bin.mix),
# with those documents as the app writes them (documents/<case>.json: 1b's reverted to version 1, as 1b wrote them),
# recorded once from the branch golden-2-base (main with no change to the app's sources, only test code and this
# Makefile), outside git, with fixtures.sha (the digests of the cases' video the frames were drawn from, which tell a
# change of the render from other video of the encoder), VERSION (the fingerprint of scripts/golden-system.sh) and COMMIT
# (the commit they were recorded from). They live next to 1b's and 1c's in the main checkout. Recording needs
# EditDocument.currentVersion 2, which no code of phase 2 has; with phase 2's code the same documents, migrated, must draw
# and sound the same. Record them with the Mac doing no other video work.
GOLDEN_2_DIR ?= $(or $(GOLDEN_ROOT),$(CURDIR)/)build/golden-2
GOLDEN_2 = $(abspath $(GOLDEN_2_DIR))
GOLDEN_2_SRC = $(or $(GOLDEN_ROOT),$(CURDIR)/)build/golden-2-src
GOLDEN_2_TESTS = swift test --package-path Packages/RecorderKit --filter 'golden2FramesMatch|golden2MixMatches'
# Sets $$commit to the commit the golden files of phase 2 were recorded from.
GOLDEN_2_COMMIT = commit=$$(cat "$(GOLDEN_2)/COMMIT" 2>/dev/null || echo "<the last commit of the branch golden-2-base>")
# Records them again from $$commit, in a worktree of that commit, with the ones there moved aside.
GOLDEN_2_RECORD_AGAIN = mv '$(GOLDEN_2)' '$(GOLDEN_2).old' && git worktree add '$(GOLDEN_2_SRC)' $$commit \
	&& make -C '$(GOLDEN_2_SRC)' golden-2-record GOLDEN_2_DIR='$(GOLDEN_2)' && git worktree remove '$(GOLDEN_2_SRC)'
# Whether both golden tests of phase 2 ran and passed, from the output of GOLDEN_2_TESTS in file $(1): a filter that
# matches no test exits with 0 too.
GOLDEN_2_RAN = { grep -qF 'golden2FramesMatch() passed' "$(1)" && grep -qF 'golden2MixMatches() passed' "$(1)" \
	|| { echo "golden2FramesMatch and golden2MixMatches did not both run and pass: nothing was compared" >&2; false; }; }

golden-2 golden-2-record: SHELL := /bin/bash

golden-2:
	@$(GOLDEN_2_COMMIT); \
	for file in frames.bin frames.bin.mix documents fixtures.sha COMMIT; do \
		if [ ! -e "$(GOLDEN_2)/$$file" ]; then \
			echo "no $(GOLDEN_2)/$$file: the golden files of phase 2 are recorded whole, once; record them again from the commit in $(GOLDEN_2_DIR)/COMMIT, never from later code (phase 2 design §14):" >&2; \
			echo "  $(GOLDEN_2_RECORD_AGAIN)" >&2; \
			exit 1; \
		fi; \
	done; \
	if [ ! -f "$(GOLDEN_2)/VERSION" ]; then \
		echo "no $(GOLDEN_2)/VERSION, the fingerprint of the system the golden files of phase 2 were recorded on: they cannot be compared without it; record them again from the commit in $(GOLDEN_2_DIR)/COMMIT, never from later code (phase 2 design §14):" >&2; \
		echo "  $(GOLDEN_2_RECORD_AGAIN)" >&2; \
		exit 1; \
	fi; \
	now=$$(mktemp -t toma-golden-2); \
	bash scripts/golden-system.sh > "$$now" || { rm -f "$$now"; echo "scripts/golden-system.sh failed: no fingerprint of this system to compare" >&2; exit 1; }; \
	if ! cmp -s "$(GOLDEN_2)/VERSION" "$$now"; then \
		echo "the system changed since the golden files in $(GOLDEN_2) were recorded (< then, > now):" >&2; \
		diff "$(GOLDEN_2)/VERSION" "$$now" >&2; \
		rm -f "$$now"; \
		echo "record them again from the commit in $(GOLDEN_2_DIR)/COMMIT, never from later code (phase 2 design §14):" >&2; \
		echo "  $(GOLDEN_2_RECORD_AGAIN)" >&2; \
		exit 1; \
	fi; \
	rm -f "$$now"
	@set -o pipefail; log=$$(mktemp -t toma-golden-2); \
	TOMA_GOLDEN_2_DIR="$(GOLDEN_2)" $(GOLDEN_2_TESTS) 2>&1 | tee "$$log" && $(call GOLDEN_2_RAN,$$log); \
	status=$$?; rm -f "$$log"; exit $$status

# Records into $(GOLDEN_2).partial and moves that into place only once both tests passed and VERSION and COMMIT are
# written: the golden files of phase 2 are there whole or not at all.
golden-2-record:
	@$(GOLDEN_2_COMMIT); \
	if [ -e "$(GOLDEN_2)" ]; then \
		echo "$(GOLDEN_2) is already there: the golden files of phase 2 are recorded once, from the branch golden-2-base, never over others (phase 2 design §14)." >&2; \
		echo "To record them again from the commit in $(GOLDEN_2_DIR)/COMMIT, never from later code (phase 2 design §14): $(GOLDEN_2_RECORD_AGAIN)" >&2; \
		exit 1; \
	fi
	@test -z "$$(git status --porcelain)" || { echo "this checkout has uncommitted changes: the golden files of phase 2 are recorded from a commit, which they name in COMMIT" >&2; exit 1; }
	@set -o pipefail; log=$$(mktemp -t toma-golden-2); \
	rm -rf "$(GOLDEN_2).partial" && mkdir -p "$(GOLDEN_2).partial" && \
	TOMA_GOLDEN_2_DIR="$(GOLDEN_2).partial" TOMA_GOLDEN_RECORD=1 $(GOLDEN_2_TESTS) 2>&1 | tee "$$log" && \
	$(call GOLDEN_2_RAN,$$log) && \
	bash scripts/golden-system.sh > "$(GOLDEN_2).partial/VERSION" && git rev-parse HEAD > "$(GOLDEN_2).partial/COMMIT" && \
	test ! -e "$(GOLDEN_2)" && mv "$(GOLDEN_2).partial" "$(GOLDEN_2)"; \
	status=$$?; rm -f "$$log"; \
	if [ $$status -eq 0 ]; then \
		echo "recorded $(GOLDEN_2) from $$(cat "$(GOLDEN_2)/COMMIT")"; \
	else \
		rm -rf "$(GOLDEN_2).partial"; echo "nothing recorded in $(GOLDEN_2)" >&2; \
	fi; \
	exit $$status

# The golden files of phase 3 (phase 3 design §16, "golden 3"): the frames and the mix of the edit documents of 1b
# (documentVersion 1), of 1c (2) and of phase 2 (3) of GoldenDocuments (golden3Cases: golden 2's cases, then phase 2's
# captions, privacy, keys, device frame, camera look, Follow the Cursor, formats and Normalize, without any model of the
# system: frames.bin and frames.bin.mix), with those documents as the app writes them (documents/<case>.json: 1b's and
# 1c's reverted to their versions), recorded once from the branch golden-3-base (main with no change to the app's
# sources, only test code and this Makefile), outside git, with fixtures.sha (the digests of the cases' video the frames
# were drawn from, which tell a change of the render from other video of the encoder), VERSION (the fingerprint of
# scripts/golden-system.sh) and COMMIT (the commit they were recorded from). They live next to the others in the main
# checkout. Recording needs EditDocument.currentVersion 3, which no code of phase 3 has; with phase 3's code the same
# documents, migrated, must draw and sound the same. In phase 3 it is the gate of every change of the render or the
# export. Record them with the Mac doing no other video work.
GOLDEN_3_DIR ?= $(or $(GOLDEN_ROOT),$(CURDIR)/)build/golden-3
GOLDEN_3 = $(abspath $(GOLDEN_3_DIR))
GOLDEN_3_SRC = $(or $(GOLDEN_ROOT),$(CURDIR)/)build/golden-3-src
# What golden 3 compares: the frames, the mix, and that every golden document, migrated, keeps the rules of the document
# of phase 3 (theGoldenDocumentsHaveNoProblem: none of them turns read-only). Recording runs the first two alone.
GOLDEN_3_TESTS = swift test --package-path Packages/RecorderKit --filter 'golden3FramesMatch|golden3MixMatches|theGoldenDocumentsHaveNoProblem'
GOLDEN_3_RECORD_TESTS = swift test --package-path Packages/RecorderKit --filter 'golden3FramesMatch|golden3MixMatches'
# Sets $$commit to the commit the golden files of phase 3 were recorded from.
GOLDEN_3_COMMIT = commit=$$(cat "$(GOLDEN_3)/COMMIT" 2>/dev/null || echo "<the last commit of the branch golden-3-base>")
# Records them again from $$commit, in a worktree of that commit, with the ones there moved aside.
GOLDEN_3_RECORD_AGAIN = mv '$(GOLDEN_3)' '$(GOLDEN_3).old' && git worktree add '$(GOLDEN_3_SRC)' $$commit \
	&& make -C '$(GOLDEN_3_SRC)' golden-3-record GOLDEN_3_DIR='$(GOLDEN_3)' && git worktree remove '$(GOLDEN_3_SRC)'
# Whether every golden test of phase 3 ran and passed, from the output of GOLDEN_3_TESTS in file $(1): a filter that
# matches no test exits with 0 too.
GOLDEN_3_RAN = { grep -qF 'golden3FramesMatch() passed' "$(1)" && grep -qF 'golden3MixMatches() passed' "$(1)" \
	&& grep -qF 'theGoldenDocumentsHaveNoProblem() passed' "$(1)" \
	|| { echo "golden3FramesMatch, golden3MixMatches and theGoldenDocumentsHaveNoProblem did not all run and pass: nothing was compared" >&2; false; }; }
# The same for the two tests a recording runs (GOLDEN_3_RECORD_TESTS).
GOLDEN_3_RECORDED = { grep -qF 'golden3FramesMatch() passed' "$(1)" && grep -qF 'golden3MixMatches() passed' "$(1)" \
	|| { echo "golden3FramesMatch and golden3MixMatches did not both run and pass: nothing was recorded" >&2; false; }; }

golden-3 golden-3-record: SHELL := /bin/bash

golden-3:
	@$(GOLDEN_3_COMMIT); \
	for file in frames.bin frames.bin.mix documents fixtures.sha COMMIT; do \
		if [ ! -e "$(GOLDEN_3)/$$file" ]; then \
			echo "no $(GOLDEN_3)/$$file: the golden files of phase 3 are recorded whole, once; record them again from the commit in $(GOLDEN_3_DIR)/COMMIT, never from later code (phase 3 design §16):" >&2; \
			echo "  $(GOLDEN_3_RECORD_AGAIN)" >&2; \
			exit 1; \
		fi; \
	done; \
	if [ ! -f "$(GOLDEN_3)/VERSION" ]; then \
		echo "no $(GOLDEN_3)/VERSION, the fingerprint of the system the golden files of phase 3 were recorded on: they cannot be compared without it; record them again from the commit in $(GOLDEN_3_DIR)/COMMIT, never from later code (phase 3 design §16):" >&2; \
		echo "  $(GOLDEN_3_RECORD_AGAIN)" >&2; \
		exit 1; \
	fi; \
	now=$$(mktemp -t toma-golden-3); \
	bash scripts/golden-system.sh > "$$now" || { rm -f "$$now"; echo "scripts/golden-system.sh failed: no fingerprint of this system to compare" >&2; exit 1; }; \
	if ! cmp -s "$(GOLDEN_3)/VERSION" "$$now"; then \
		echo "the system changed since the golden files in $(GOLDEN_3) were recorded (< then, > now):" >&2; \
		diff "$(GOLDEN_3)/VERSION" "$$now" >&2; \
		rm -f "$$now"; \
		echo "record them again from the commit in $(GOLDEN_3_DIR)/COMMIT, never from later code (phase 3 design §16):" >&2; \
		echo "  $(GOLDEN_3_RECORD_AGAIN)" >&2; \
		exit 1; \
	fi; \
	rm -f "$$now"
	@set -o pipefail; log=$$(mktemp -t toma-golden-3); \
	TOMA_GOLDEN_3_DIR="$(GOLDEN_3)" $(GOLDEN_3_TESTS) 2>&1 | tee "$$log" && $(call GOLDEN_3_RAN,$$log); \
	status=$$?; rm -f "$$log"; exit $$status

# Records into $(GOLDEN_3).partial and moves that into place only once both tests passed and VERSION and COMMIT are
# written: the golden files of phase 3 are there whole or not at all.
golden-3-record:
	@$(GOLDEN_3_COMMIT); \
	if [ -e "$(GOLDEN_3)" ]; then \
		echo "$(GOLDEN_3) is already there: the golden files of phase 3 are recorded once, from the branch golden-3-base, never over others (phase 3 design §16)." >&2; \
		echo "To record them again from the commit in $(GOLDEN_3_DIR)/COMMIT, never from later code (phase 3 design §16): $(GOLDEN_3_RECORD_AGAIN)" >&2; \
		exit 1; \
	fi
	@test -z "$$(git status --porcelain)" || { echo "this checkout has uncommitted changes: the golden files of phase 3 are recorded from a commit, which they name in COMMIT" >&2; exit 1; }
	@set -o pipefail; log=$$(mktemp -t toma-golden-3); \
	rm -rf "$(GOLDEN_3).partial" && mkdir -p "$(GOLDEN_3).partial" && \
	TOMA_GOLDEN_3_DIR="$(GOLDEN_3).partial" TOMA_GOLDEN_RECORD=1 $(GOLDEN_3_RECORD_TESTS) 2>&1 | tee "$$log" && \
	$(call GOLDEN_3_RECORDED,$$log) && \
	bash scripts/golden-system.sh > "$(GOLDEN_3).partial/VERSION" && git rev-parse HEAD > "$(GOLDEN_3).partial/COMMIT" && \
	test ! -e "$(GOLDEN_3)" && mv "$(GOLDEN_3).partial" "$(GOLDEN_3)"; \
	status=$$?; rm -f "$$log"; \
	if [ $$status -eq 0 ]; then \
		echo "recorded $(GOLDEN_3) from $$(cat "$(GOLDEN_3)/COMMIT")"; \
	else \
		rm -rf "$(GOLDEN_3).partial"; echo "nothing recorded in $(GOLDEN_3)" >&2; \
	fi; \
	exit $$status

# The golden files of phases 4 and 5 (phases 4 and 5 design §4.2, "golden 4"): golden 3's cases (edit documents of 1b,
# 1c and phase 2, documentVersion 1 to 3) and a project of phase 3 (GoldenPhase3Project: two takes, a title card, a
# frozen frame, an imported clip, a text, an arrow and a step, a Dim block and a loupe, the theme library:music-1/calm
# with ducking, a J cut, a stretch at -6 dB and two markers, documentVersion 4) of GoldenPhase3Project.golden4Cases:
# their frames (frames.bin), their mix (frames.bin.mix) and their documents as the app of phase 3 writes them
# (documents/<case>.json), recorded once from the commit of task B2 of the base of phases 4 and 5 (phase 3's code with
# only test code and this Makefile changed, before document 5), outside git, with fixtures.sha (the digests of the
# video the frames were drawn from, which tell a change of the render from other video of the encoder), VERSION (the
# fingerprint of scripts/golden-system.sh) and COMMIT (the commit they were recorded from). They live next to the others
# in the main checkout. Recording needs EditDocument.currentVersion 4 at the commit recorded from, which golden-4-record
# reads from git, and which no code of phases 4 and 5 has; with their code the same documents, migrated, must draw and
# sound the same, and written back in their versions be the same bytes. In phases 4 and 5 it is the gate of every
# change of the render, the export or the document. Record them with the Mac doing no other video work.
GOLDEN_4_DIR ?= $(or $(GOLDEN_ROOT),$(CURDIR)/)build/golden-4
GOLDEN_4 = $(abspath $(GOLDEN_4_DIR))
GOLDEN_4_SRC = $(or $(GOLDEN_ROOT),$(CURDIR)/)build/golden-4-src
# What golden 4 compares: the frames, the mix, and the documents (golden4DocumentsMatch: each one, migrated, keeps the
# rules of the document and written back in its version is the bytes recorded). Recording runs the first two alone.
GOLDEN_4_TESTS = swift test --package-path Packages/RecorderKit --filter 'golden4FramesMatch|golden4MixMatches|golden4DocumentsMatch'
GOLDEN_4_RECORD_TESTS = swift test --package-path Packages/RecorderKit --filter 'golden4FramesMatch|golden4MixMatches'
# Prints EditDocument.currentVersion of the commit checked out (HEAD), read from git: golden 4 is recorded only from one
# of version 4.
GOLDEN_4_DOCUMENT_VERSION = git show HEAD:Packages/RecorderKit/Sources/ProjectFormat/EditDocument.swift \
	| sed -n 's/^[[:space:]]*public static let currentVersion = \([0-9][0-9]*\)[[:space:]]*$$/\1/p'
# Sets $$commit to the commit the golden files of golden 4 were recorded from.
GOLDEN_4_COMMIT = commit=$$(cat "$(GOLDEN_4)/COMMIT" 2>/dev/null || echo "<the commit of task B2 of the base of phases 4 and 5>")
# Records them again from $$commit, in a worktree of that commit, with the ones there moved aside.
GOLDEN_4_RECORD_AGAIN = mv '$(GOLDEN_4)' '$(GOLDEN_4).old' && git worktree add '$(GOLDEN_4_SRC)' $$commit \
	&& make -C '$(GOLDEN_4_SRC)' golden-4-record GOLDEN_4_DIR='$(GOLDEN_4)' && git worktree remove '$(GOLDEN_4_SRC)'
# Whether every golden test of golden 4 ran and passed, from the output of GOLDEN_4_TESTS in file $(1): a filter that
# matches no test exits with 0 too.
GOLDEN_4_RAN = { grep -qF 'golden4FramesMatch() passed' "$(1)" && grep -qF 'golden4MixMatches() passed' "$(1)" \
	&& grep -qF 'golden4DocumentsMatch() passed' "$(1)" \
	|| { echo "golden4FramesMatch, golden4MixMatches and golden4DocumentsMatch did not all run and pass: nothing was compared" >&2; false; }; }
# The same for the two tests a recording runs (GOLDEN_4_RECORD_TESTS).
GOLDEN_4_RECORDED = { grep -qF 'golden4FramesMatch() passed' "$(1)" && grep -qF 'golden4MixMatches() passed' "$(1)" \
	|| { echo "golden4FramesMatch and golden4MixMatches did not both run and pass: nothing was recorded" >&2; false; }; }

golden-4 golden-4-record: SHELL := /bin/bash

golden-4:
	@$(GOLDEN_4_COMMIT); \
	for file in frames.bin frames.bin.mix documents fixtures.sha COMMIT; do \
		if [ ! -e "$(GOLDEN_4)/$$file" ]; then \
			echo "no $(GOLDEN_4)/$$file: the golden files of golden 4 are recorded whole, once; record them again from the commit in $(GOLDEN_4_DIR)/COMMIT, never from later code (phases 4 and 5 design §4.2):" >&2; \
			echo "  $(GOLDEN_4_RECORD_AGAIN)" >&2; \
			exit 1; \
		fi; \
	done; \
	if [ ! -f "$(GOLDEN_4)/VERSION" ]; then \
		echo "no $(GOLDEN_4)/VERSION, the fingerprint of the system the golden files of golden 4 were recorded on: they cannot be compared without it; record them again from the commit in $(GOLDEN_4_DIR)/COMMIT, never from later code (phases 4 and 5 design §4.2):" >&2; \
		echo "  $(GOLDEN_4_RECORD_AGAIN)" >&2; \
		exit 1; \
	fi; \
	now=$$(mktemp -t toma-golden-4); \
	bash scripts/golden-system.sh > "$$now" || { rm -f "$$now"; echo "scripts/golden-system.sh failed: no fingerprint of this system to compare" >&2; exit 1; }; \
	if ! cmp -s "$(GOLDEN_4)/VERSION" "$$now"; then \
		echo "the system changed since the golden files in $(GOLDEN_4) were recorded (< then, > now):" >&2; \
		diff "$(GOLDEN_4)/VERSION" "$$now" >&2; \
		rm -f "$$now"; \
		echo "record them again from the commit in $(GOLDEN_4_DIR)/COMMIT, never from later code (phases 4 and 5 design §4.2):" >&2; \
		echo "  $(GOLDEN_4_RECORD_AGAIN)" >&2; \
		exit 1; \
	fi; \
	rm -f "$$now"
	@set -o pipefail; log=$$(mktemp -t toma-golden-4); \
	TOMA_GOLDEN_4_DIR="$(GOLDEN_4)" $(GOLDEN_4_TESTS) 2>&1 | tee "$$log" && $(call GOLDEN_4_RAN,$$log); \
	status=$$?; rm -f "$$log"; exit $$status

# Records into $(GOLDEN_4).partial and moves that into place only once both tests passed and VERSION and COMMIT are
# written: the golden files of golden 4 are there whole or not at all. Only from a clean checkout of a commit whose
# EditDocument.currentVersion is 4 (GOLDEN_4_DOCUMENT_VERSION): from code of phases 4 and 5 they would protect nothing.
golden-4-record:
	@$(GOLDEN_4_COMMIT); \
	if [ -e "$(GOLDEN_4)" ]; then \
		echo "$(GOLDEN_4) is already there: the golden files of golden 4 are recorded once, from the commit of task B2 of the base of phases 4 and 5, never over others (phases 4 and 5 design §4.2)." >&2; \
		echo "To record them again from the commit in $(GOLDEN_4_DIR)/COMMIT, never from later code (phases 4 and 5 design §4.2): $(GOLDEN_4_RECORD_AGAIN)" >&2; \
		exit 1; \
	fi
	@test -z "$$(git status --porcelain)" || { echo "this checkout has uncommitted changes: the golden files of golden 4 are recorded from a commit, which they name in COMMIT" >&2; exit 1; }
	@version=$$($(GOLDEN_4_DOCUMENT_VERSION)); \
	if [ "$$version" != 4 ]; then \
		echo "EditDocument.currentVersion is $${version:-unknown} at $$(git rev-parse --short HEAD), not 4: golden 4 holds documents of phase 3 and is recorded only from a commit before document 5, never from later code (phases 4 and 5 design §4.2)" >&2; \
		exit 1; \
	fi
	@set -o pipefail; log=$$(mktemp -t toma-golden-4); \
	rm -rf "$(GOLDEN_4).partial" && mkdir -p "$(GOLDEN_4).partial" && \
	TOMA_GOLDEN_4_DIR="$(GOLDEN_4).partial" TOMA_GOLDEN_RECORD=1 $(GOLDEN_4_RECORD_TESTS) 2>&1 | tee "$$log" && \
	$(call GOLDEN_4_RECORDED,$$log) && \
	bash scripts/golden-system.sh > "$(GOLDEN_4).partial/VERSION" && git rev-parse HEAD > "$(GOLDEN_4).partial/COMMIT" && \
	test ! -e "$(GOLDEN_4)" && mv "$(GOLDEN_4).partial" "$(GOLDEN_4)"; \
	status=$$?; rm -f "$$log"; \
	if [ $$status -eq 0 ]; then \
		echo "recorded $(GOLDEN_4) from $$(cat "$(GOLDEN_4)/COMMIT")"; \
	else \
		rm -rf "$(GOLDEN_4).partial"; echo "nothing recorded in $(GOLDEN_4)" >&2; \
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
