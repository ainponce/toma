// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Recording
import Synchronization
import Testing

// The Replay's controller (fases 4 y 5 design §10.2–§10.4, plan 5c decisions 10 to 17): the real ring of
// `ReplayCoordinator` from synthetic sources (`FakeFactory`), at scale (segments of 1 s), in real time, saved by the
// real `ReplaySaver`.

@MainActor @Suite(.serialized) struct ReplayControllerTests {
    @Test func enablingStartsAndWritesTheSetting() async throws {
        try await withReplay { rig in
            await rig.controller.launch()
            #expect(rig.controller.phase == .off && !rig.controller.isEnabled && rig.controller.problem == nil)
            #expect(!rig.scratchExists && rig.calls.prepared.isEmpty)

            rig.controller.setEnabled(true)
            #expect(rig.store.settings.replay.enabled && rig.controller.isEnabled)
            #expect(await eventually { rig.controller.phase == .on(since: ReplayRig.now) })
            #expect(rig.scratchExists && ReplayScratch.isScratch(rig.package))
            #expect(rig.controller.recordedKinds == [.display, .microphone])
            #expect(rig.controller.problem == nil)
            #expect(rig.calls.prepared.map(\.selection) == [.mainDisplay(1)])
            #expect(rig.calls.prepared.map(\.seconds) == [30])
            #expect(rig.calls.started.map(\.package.url) == [rig.package.url])
            #expect(rig.calls.started.map(\.selection) == [.mainDisplay(1)])
            #expect(rig.calls.phaseChanges >= 2)  // starting, on

            // The setting is the user's: another controller of the same settings sees it on.
            #expect(rig.store.settings.replay == ReplayPreferences(enabled: true, seconds: 30))
            #expect(ReplayController(probe: rig.probe, environment: rig.environment, store: rig.store).isEnabled)
        }
    }

    @Test func disablingDiscards() async throws {
        try await withReplay(enabled: true) { rig in
            await rig.controller.launch()
            #expect(rig.controller.phase == .on(since: ReplayRig.now) && rig.scratchExists)

            rig.controller.setEnabled(false)
            #expect(!rig.store.settings.replay.enabled && !rig.controller.isEnabled)
            #expect(await eventually { rig.controller.phase == .off })
            #expect(!rig.scratchExists)
            #expect(rig.controller.recordedKinds.isEmpty && rig.controller.problem == nil)
            // Saving does nothing while it is off.
            #expect(await rig.controller.save() == nil)
            #expect(rig.savedProjects().isEmpty)
        }
    }

    @Test func neverAsksForAPermission() async throws {
        let probe = ReplayProbe([.screenRecording: .notDetermined, .microphone: .notDetermined, .camera: .notDetermined])
        var selection = CaptureSelection.mainDisplay(1)
        selection.camera = .systemDefault
        try await withReplay(probe: probe, selection: selection, enabled: true) { rig in
            await rig.controller.launch()
            #expect(rig.controller.phase == .off && rig.controller.problem == .noScreenRecording)
            #expect(rig.calls.heldOff == [.noScreenRecording])
            #expect(rig.controller.isEnabled && rig.store.settings.replay.enabled)
            #expect(!rig.scratchExists && rig.calls.prepared.isEmpty)

            // Screen recording allowed in System Settings: the screen alone, the microphone and the camera never asked.
            probe.set(.screenRecording, .granted)
            rig.controller.setEnabled(true)
            #expect(await eventually { rig.controller.phase == .on(since: ReplayRig.now) })
            #expect(rig.controller.recordedKinds == [.display] && rig.controller.problem == nil)
            #expect(rig.calls.prepared.last?.selection == CaptureSelection(
                mode: .display, displayIDs: [1], camera: .off, microphone: .off, systemAudio: .off))
            #expect(rig.calls.prepared.last?.granted == [.screenRecording])
            #expect(probe.requests.isEmpty)
        }
    }

    @Test func takeStopsTheReplayBeforeItsSourcesStart() async throws {
        try await withReplay(enabled: true) { rig in
            await rig.controller.launch()
            #expect(rig.scratchExists)

            await rig.controller.suspendForTake()
            #expect(rig.controller.phase == .suspended)
            #expect(!rig.scratchExists)
            #expect(rig.controller.recordedKinds.isEmpty && rig.controller.isEnabled && rig.controller.problem == nil)
            #expect(await rig.controller.save() == nil)
            // Nothing comes back by itself during the take.
            rig.activity.yield(.screenLocked)
            rig.activity.yield(.screenUnlocked)
            try await Task.sleep(for: .milliseconds(300))
            #expect(rig.controller.phase == .suspended && !rig.scratchExists && rig.calls.prepared.count == 1)
        }
    }

    @Test func saveInProgressFinishesBeforeTheTake() async throws {
        try await withReplay(enabled: true) { rig in
            await rig.controller.launch()
            try await Task.sleep(for: .milliseconds(1600))
            rig.saveGate.close()
            let saving = Task { await rig.controller.save() }
            #expect(await eventually { rig.saveGate.arrivals == 1 && rig.controller.phase == .saving })

            var suspended = false
            let suspending = Task {
                await rig.controller.suspendForTake()
                suspended = true
            }
            try await Task.sleep(for: .milliseconds(300))
            // The take waits: the ring is still there for the save.
            #expect(!suspended && rig.scratchExists)

            rig.saveGate.open()
            let saved = try #require(await saving.value)
            await suspending.value
            #expect(suspended && rig.controller.phase == .suspended && !rig.scratchExists)
            let project = try LoadedProject.load(saved.projectURL)
            #expect(project.take.status == .complete)
            #expect(rig.savedProjects() == [saved.projectURL.lastPathComponent])
        }
    }

    @Test func replayComesBackAfterTheTake() async throws {
        try await withReplay(enabled: true) { rig in
            await rig.controller.launch()
            let before = try rig.scratchProjectID()
            await rig.controller.suspendForTake()
            #expect(!rig.scratchExists)

            let resumed = HostTime.now()
            rig.controller.resumeAfterTake()
            #expect(await eventually { rig.controller.phase == .on(since: ReplayRig.now) })
            #expect(rig.scratchExists)
            // A new working package: nothing of before the take.
            #expect(try rig.scratchProjectID() != before)
            #expect(await eventually { (try? rig.scratchSegments().isEmpty) == false })
            #expect(try rig.scratchSegments().allSatisfy { $0.startHostTime >= resumed })
            #expect(rig.calls.prepared.count == 2 && rig.calls.started.count == 2)
            #expect(rig.controller.recordedKinds == [.display, .microphone])
        }
    }

    @Test func disabledDuringATakeStaysOff() async throws {
        try await withReplay(enabled: true) { rig in
            await rig.controller.launch()
            await rig.controller.suspendForTake()
            rig.controller.setEnabled(false)
            #expect(await eventually { rig.controller.phase == .off })
            rig.controller.resumeAfterTake()
            try await Task.sleep(for: .milliseconds(300))
            #expect(rig.controller.phase == .off && !rig.scratchExists && rig.calls.prepared.count == 1)

            // Turned on during the next take, it waits for its end.
            await rig.controller.suspendForTake()
            rig.controller.setEnabled(true)
            #expect(await eventually { rig.controller.phase == .suspended })
            try await Task.sleep(for: .milliseconds(300))
            #expect(!rig.scratchExists && rig.calls.prepared.count == 1)
            rig.controller.resumeAfterTake()
            #expect(await eventually { rig.controller.phase == .on(since: ReplayRig.now) })
        }
    }

    @Test func lockDiscardsAndUnlockStartsAfresh() async throws {
        try await withReplay(enabled: true) { rig in
            await rig.controller.launch()
            let before = try rig.scratchProjectID()

            rig.activity.yield(.screenLocked)
            #expect(await eventually { rig.controller.phase == .suspended && !rig.scratchExists })
            rig.activity.yield(.screenUnlocked)
            #expect(await eventually { rig.controller.phase == .on(since: ReplayRig.now) })
            #expect(try rig.scratchProjectID() != before)
            #expect(rig.calls.prepared.count == 2)
        }
    }

    @Test func sleepDiscardsAndWakeStartsAfresh() async throws {
        try await withReplay(enabled: true) { rig in
            await rig.controller.launch()
            let before = try rig.scratchProjectID()

            rig.activity.yield(.willSleep)
            #expect(await eventually { rig.controller.phase == .suspended && !rig.scratchExists })
            rig.activity.yield(.didWake)
            #expect(await eventually { rig.controller.phase == .on(since: ReplayRig.now) })
            #expect(try rig.scratchProjectID() != before)

            // Woken onto the lock screen: it waits for the unlock.
            rig.activity.yield(.screenLocked)
            rig.activity.yield(.willSleep)
            #expect(await eventually { rig.controller.phase == .suspended && !rig.scratchExists })
            rig.activity.yield(.didWake)
            try await Task.sleep(for: .milliseconds(300))
            #expect(rig.controller.phase == .suspended && !rig.scratchExists && rig.calls.prepared.count == 2)
            rig.activity.yield(.screenUnlocked)
            #expect(await eventually { rig.controller.phase == .on(since: ReplayRig.now) })
            #expect(rig.calls.prepared.count == 3)
        }
    }

    @Test func diskFullTurnsItOffWithAProblem() async throws {
        try await withReplay(enabled: true) { rig in
            await rig.controller.launch()
            rig.disk.set(importantUsage: 9_000_000_000, available: 500_000_000)
            #expect(await eventually { rig.controller.phase == .off && rig.controller.problem == .diskFull })
            // It stopped by itself: the app is told, to say so.
            #expect(rig.calls.heldOff == [.diskFull])
            #expect(!rig.scratchExists && rig.controller.recordedKinds.isEmpty)
            #expect(rig.controller.isEnabled && rig.store.settings.replay.enabled)

            // It does not come back by itself, not even after a lock.
            rig.disk.set(importantUsage: 100_000_000_000, available: 100_000_000_000)
            rig.activity.yield(.screenLocked)
            rig.activity.yield(.screenUnlocked)
            try await Task.sleep(for: .milliseconds(300))
            #expect(rig.controller.phase == .off && rig.controller.problem == .diskFull && rig.calls.prepared.count == 1)

            // After the next take it tries again.
            await rig.controller.suspendForTake()
            rig.controller.resumeAfterTake()
            #expect(await eventually { rig.controller.phase == .on(since: ReplayRig.now) })
            #expect(rig.controller.problem == nil && rig.scratchExists)
        }
    }

    @Test func diskTooFullToStartSaysSo() async throws {
        try await withReplay(enabled: true) { rig in
            rig.disk.set(importantUsage: 1_000_000_000, available: 1_000_000_000)
            await rig.controller.launch()
            #expect(rig.controller.phase == .off && rig.controller.problem == .diskFull && !rig.scratchExists)
        }
    }

    @Test func saveGivesASavedTakeWithItsSeconds() async throws {
        try await withReplay(enabled: true) { rig in
            await rig.controller.launch()
            try await Task.sleep(for: .milliseconds(2600))

            let saved = try #require(await rig.controller.save())
            let name = ProjectFolder.baseName(prefix: "Replay", date: ReplayRig.now)
            #expect(saved.projectURL.lastPathComponent == name + ".toma")
            #expect(saved.projectURL.deletingLastPathComponent().standardizedFileURL == rig.projects.standardizedFileURL)
            #expect(saved.markers == 0 && !saved.openedEditor)
            #expect(saved.trackKinds == [.display, .microphone])
            // The seconds it saved, not N: «Guardado: últimos 2 s».
            #expect(saved.replaySeconds == Int(saved.duration.seconds.rounded()))
            #expect(saved.duration >= .seconds(2) && saved.duration < .seconds(15), "\(saved.duration)")
            #expect(rig.calls.saved == [saved])
            #expect(rig.controller.phase == .on(since: ReplayRig.now) && rig.controller.problem == nil)
            #expect(rig.scratchExists)

            let project = try LoadedProject.load(saved.projectURL)
            #expect(project.take.status == .complete)
            #expect(project.take.tracks.map(\.kind) == [.display, .microphone])

            // A second save of the same second is « 2».
            let again = try #require(await rig.controller.save())
            #expect(again.projectURL.lastPathComponent == name + " 2.toma")
            #expect(rig.calls.saved == [saved, again])
        }
    }

    @Test func aSaveRightAfterTheStartIsTooShort() async throws {
        try await withReplay(enabled: true) { rig in
            await rig.controller.launch()
            #expect(await rig.controller.save() == nil)
            #expect(rig.controller.problem == .tooShort)
            #expect(rig.controller.phase == .on(since: ReplayRig.now))
            #expect(rig.savedProjects().isEmpty && rig.calls.saved.isEmpty && rig.saveGate.arrivals == 0)
        }
    }

    @Test func aFailedSaveSaysSo() async throws {
        try await withReplay(enabled: true) { rig in
            // The projects folder cannot be made: a file has its name.
            try FileManager.default.createDirectory(at: rig.projects.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: rig.projects)
            await rig.controller.launch()
            try await Task.sleep(for: .milliseconds(1600))
            #expect(await rig.controller.save() == nil)
            #expect(rig.controller.problem == .saveFailed)
            #expect(rig.controller.phase == .on(since: ReplayRig.now) && rig.scratchExists && rig.calls.saved.isEmpty)
        }
    }

    @Test func secondSaveWhileSavingIsIgnored() async throws {
        try await withReplay(enabled: true) { rig in
            await rig.controller.launch()
            try await Task.sleep(for: .milliseconds(1600))
            rig.saveGate.close()
            let first = Task { await rig.controller.save() }
            #expect(await eventually { rig.controller.phase == .saving })

            // It answers at once, without waiting for the first.
            var second: SavedTake??
            let asking = Task { second = .some(await rig.controller.save()) }
            #expect(await eventually(timeout: .seconds(1)) { second != nil })
            #expect(second == .some(nil))
            #expect(rig.controller.problem == nil && rig.saveGate.arrivals == 1)
            rig.saveGate.open()
            #expect(await first.value != nil)
            await asking.value
            #expect(rig.savedProjects().count == 1 && rig.calls.saved.count == 1)
            #expect(rig.controller.phase == .on(since: ReplayRig.now))
        }
    }

    @Test func shorterThanNSavesWhatThereIs() async throws {
        try await withReplay(enabled: true, seconds: 15) { rig in
            await rig.controller.launch()
            try await Task.sleep(for: .milliseconds(2500))
            let saved = try #require(await rig.controller.save())
            // Less than N was recorded: all of it, from the start of the screen.
            #expect(saved.duration >= .seconds(2) && saved.duration <= .seconds(4), "\(saved.duration)")
            #expect(saved.replaySeconds.map { $0 >= 2 && $0 <= 4 } == true)
            let project = try LoadedProject.load(saved.projectURL)
            let screen = try #require(project.take.tracks.first { $0.kind == .display }).segments
            let first = try #require(screen.first?.startHostTime)
            let last = try #require(screen.compactMap(\.endHostTime).max())
            #expect(abs(last.seconds(since: first) - saved.duration.seconds) < 0.1, "\(last.seconds(since: first)) s")
        }
    }

    @Test func secondsChangeAppliesLive() async throws {
        // A margin of −13 s: with N = 30 nothing goes before 17 s, with N = 15 what ended over 2 s ago goes.
        try await withReplay(enabled: true, seconds: 30, pruneMargin: .seconds(-13)) { rig in
            await rig.controller.launch()
            let first = rig.package.segmentURL(take: ReplayScratch.takeID, track: "display-1", index: 1)
            try await Task.sleep(for: .milliseconds(3500))
            #expect(FileManager.default.fileExists(atPath: first.path))

            rig.controller.setSeconds(15)
            #expect(rig.controller.seconds == 15 && rig.store.settings.replay.seconds == 15)
            #expect(await eventually { !FileManager.default.fileExists(atPath: first.path) })
            // A length the settings do not offer is not taken.
            rig.controller.setSeconds(7)
            #expect(rig.controller.seconds == 15 && rig.store.settings.replay.seconds == 15)
            // The next start takes it too.
            await rig.controller.suspendForTake()
            rig.controller.resumeAfterTake()
            #expect(await eventually { rig.controller.phase == .on(since: ReplayRig.now) })
            #expect(rig.calls.prepared.map(\.seconds) == [30, 15])
        }
    }

    @Test func launchRemovesLeftoversAndAbandonedSaves() async throws {
        try await withReplay(enabled: true) { rig in
            // What a forced quit leaves: a working package nobody records into, and a save cut short.
            let leftover = try ReplayScratch.create(in: rig.scratchRoot, app: AppInfo(name: "Tests", version: "0"), now: Date())
            let leftoverID = try rig.scratchProjectID()
            try Data("junk".utf8).write(to: rig.scratchRoot.appending(path: "junk"))
            let abandoned = rig.projects.appending(path: "." + UUID().uuidString + ReplaySaver.stagingSuffix, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
            try Data().write(to: abandoned.appending(path: ReplaySaver.lockName))
            let kept = rig.projects.appending(path: "Kept.toma", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)

            await rig.controller.launch()
            #expect(!FileManager.default.fileExists(atPath: abandoned.path))
            #expect(!FileManager.default.fileExists(atPath: rig.scratchRoot.appending(path: "junk").path))
            #expect(FileManager.default.fileExists(atPath: kept.path))
            // On: a working package of its own, not the one left.
            #expect(rig.controller.phase == .on(since: ReplayRig.now))
            #expect(leftover.url == rig.package.url)
            #expect(try rig.scratchProjectID() != leftoverID)
        }
    }

    @Test func encoderOverloadRefuses() async throws {
        try await withReplay(enabled: true) { rig in
            rig.calls.load = .over(ratio: 1.4, suggestions: [])
            await rig.controller.launch()
            #expect(rig.controller.phase == .off && rig.controller.problem == .encoderBusy)
            #expect(!rig.scratchExists && rig.calls.prepared.count == 1 && rig.calls.started.isEmpty)

            // A lot, but within the budget: it records.
            rig.calls.load = .high(ratio: 0.9, suggestions: [])
            rig.controller.setEnabled(true)
            #expect(await eventually { rig.controller.phase == .on(since: ReplayRig.now) })
            #expect(rig.controller.problem == nil)
        }
    }

    @Test func failedOptionalSourceRetriesWithTheScreenOnly() async throws {
        var selection = CaptureSelection.mainDisplay(1)
        selection.camera = .systemDefault
        selection.systemAudio = .all
        try await withReplay(selection: selection, enabled: true) { rig in
            rig.factory.microphoneFailures = 99
            await rig.controller.launch()
            #expect(rig.controller.phase == .on(since: ReplayRig.now) && rig.controller.problem == nil)
            #expect(rig.controller.recordedKinds == [.display])
            #expect(rig.calls.prepared.map(\.selection) == [
                selection, CaptureSelection(mode: .display, displayIDs: [1], camera: .off, microphone: .off, systemAudio: .off),
            ])
            #expect(rig.calls.prepared.last?.granted == [.screenRecording])
            #expect(rig.calls.started.map(\.selection) == rig.calls.prepared.dropFirst().map(\.selection))
            #expect(rig.scratchExists)
        }
    }

    @Test func aScreenThatFailsCannotStart() async throws {
        try await withReplay(enabled: true) { rig in
            rig.factory.displayFailures = 99
            await rig.controller.launch()
            #expect(rig.controller.phase == .off && rig.controller.problem == .couldNotStart)
            #expect(!rig.scratchExists && rig.calls.prepared.count == 2 && rig.calls.started.isEmpty)
        }
    }

    @Test func plannedSelectionIsWhatItRecords() async throws {
        // The last recording: display 2, the camera (not allowed) and the microphone.
        var selection = CaptureSelection.mainDisplay(2)
        selection.camera = .systemDefault
        try await withReplay(probe: ReplayProbe([.camera: .denied]), selection: selection) { rig in
            // Off, what Settings lists: what it would record now.
            let expected = CaptureSelection(mode: .display, displayIDs: [2], camera: .off, microphone: .systemDefault, systemAudio: .off)
            #expect(rig.controller.plannedSelection == expected)
            await rig.controller.launch()
            rig.controller.setEnabled(true)
            #expect(await eventually { rig.controller.phase == .on(since: ReplayRig.now) })
            #expect(rig.calls.prepared.map(\.selection) == [expected])
            #expect(rig.controller.plannedSelection == expected)
        }
    }

    @Test func cameraStyleChangeReachesTheRing() async throws {
        var selection = CaptureSelection.mainDisplay(1)
        selection.camera = .systemDefault
        try await withReplay(selection: selection, enabled: true) { rig in
            // Before it records, nothing to tell.
            rig.controller.setCameraStyle(CameraStyle(shape: .portrait, size: CameraStyle.large, anchor: .topLeading))
            await rig.controller.launch()
            #expect(rig.controller.recordedKinds.contains(.camera))
            let noted = try rig.scratchCameraStyles()
            #expect(noted.isEmpty)

            // The bubble given another shape and size while it records: its log notes it, as a take's does.
            var style = CameraStyle.default
            style.shape = .roundedSquare
            style.size = CameraStyle.large
            rig.controller.setCameraStyle(style)
            #expect(await eventually { (try? rig.scratchCameraStyles()) == [style] })
        }
    }

    @Test func aTakeDuringTheStartDeletesTheRingAtOnce() async throws {
        try await withReplay(enabled: true) { rig in
            // Its sources take their time to start.
            rig.calls.startGate.close()
            let launching = Task { await rig.controller.launch() }
            #expect(await eventually { rig.calls.startGate.arrivals == 1 && rig.controller.phase == .starting })

            // A take comes meanwhile: once the sources have started, the ring is deleted at once, without its wallpapers.
            let suspending = Task { await rig.controller.suspendForTake() }
            try await Task.sleep(for: .milliseconds(100))
            rig.calls.startGate.open()
            #expect(await suspending.value)
            await launching.value
            #expect(rig.calls.started.isEmpty)
            #expect(rig.controller.phase == .suspended && !rig.scratchExists && rig.controller.recordedKinds.isEmpty)
            #expect(rig.controller.problem == nil && rig.calls.heldOff.isEmpty)
        }
    }

    @Test func aTakeWaitsForTheReplayWithinItsTimeLimit() async throws {
        try await withReplay(enabled: true) { rig in
            await rig.controller.launch()
            try await Task.sleep(for: .milliseconds(1600))
            rig.saveGate.close()
            let saving = Task { await rig.controller.save() }
            #expect(await eventually { rig.saveGate.arrivals == 1 })

            // The save does not end for 2 s: the take goes ahead once the limit has passed.
            let opening = Task {
                try? await Task.sleep(for: .seconds(2))
                rig.saveGate.open()
            }
            let clock = ContinuousClock()
            let asked = clock.now
            let gone = await rig.controller.suspendForTake(timeLimit: .milliseconds(300))
            #expect(!gone && clock.now - asked < .milliseconds(1500))
            #expect(rig.scratchExists)

            // The Replay is deleted on its own once the save has ended, and waits for the take's end.
            await opening.value
            #expect(await saving.value != nil)
            #expect(await eventually { rig.controller.phase == .suspended && !rig.scratchExists })
            rig.controller.resumeAfterTake()
            #expect(await eventually { rig.controller.phase == .on(since: ReplayRig.now) })
        }
    }

    @Test func afterATakeItStartsAgainOnlyAfterAWhile() async throws {
        try await withReplay(enabled: true, resumeDelay: .milliseconds(700)) { rig in
            await rig.controller.launch()
            await rig.controller.suspendForTake()
            rig.controller.resumeAfterTake()
            try await Task.sleep(for: .milliseconds(300))
            #expect(rig.controller.phase == .suspended && !rig.scratchExists && rig.calls.prepared.count == 1)

            // Another take meanwhile (Record again, Re-record): no ring started and deleted for nothing.
            await rig.controller.suspendForTake()
            try await Task.sleep(for: .milliseconds(900))
            #expect(rig.controller.phase == .suspended && !rig.scratchExists && rig.calls.prepared.count == 1)

            rig.controller.resumeAfterTake()
            #expect(await eventually { rig.controller.phase == .on(since: ReplayRig.now) })
            #expect(rig.calls.prepared.count == 2)
        }
    }

    @Test func aProblemThatHoldsItOffIsToldOnce() async throws {
        try await withReplay(enabled: true) { rig in
            rig.calls.load = .over(ratio: 1.4, suggestions: [])
            await rig.controller.launch()
            #expect(rig.controller.problem == .encoderBusy && rig.calls.heldOff == [.encoderBusy])
            // Again after the next take, and told again.
            await rig.controller.suspendForTake()
            rig.controller.resumeAfterTake()
            #expect(await eventually { rig.calls.heldOff == [.encoderBusy, .encoderBusy] })
            #expect(rig.controller.phase == .off)
            // A save's problem is the save's to say, not this.
            rig.calls.load = nil
            rig.controller.setEnabled(true)
            #expect(await eventually { rig.controller.phase == .on(since: ReplayRig.now) })
            #expect(await rig.controller.save() == nil && rig.controller.problem == .tooShort)
            #expect(rig.calls.heldOff == [.encoderBusy, .encoderBusy])
        }
    }

    @Test func shutDownLeavesNoScratch() async throws {
        try await withReplay(enabled: true) { rig in
            await rig.controller.launch()
            #expect(rig.scratchExists)
            await rig.controller.shutDown()
            #expect(rig.controller.phase == .off && !rig.scratchExists)
            // Quitting is not turning it off: the setting stays, and nothing starts again.
            #expect(rig.store.settings.replay.enabled)
            rig.controller.resumeAfterTake()
            rig.activity.yield(.screenLocked)
            rig.activity.yield(.screenUnlocked)
            try await Task.sleep(for: .milliseconds(300))
            #expect(rig.controller.phase == .off && !rig.scratchExists && rig.calls.prepared.count == 1)
        }
    }
}

// MARK: - The rig

/// A controller whose Replay records `FakeFactory`'s synthetic sources into `<directory>/Replay` at scale (segments of
/// 1 s, a margin of `pruneMargin`), with displays 1 (the main one) and 2, `probe`'s permissions, a fake disk, a system
/// activity the test sends, and its saves in `<directory>/Projects`, behind `saveGate` (in `editContext`). The settings
/// start with `selection` as the last recording, the Replay `enabled` and keeping `seconds`. The controller is shut down
/// at the end.
@MainActor private func withReplay(
    probe: ReplayProbe = ReplayProbe(), selection: CaptureSelection? = .mainDisplay(1), enabled: Bool = false,
    seconds: Int = 30, pruneMargin: Duration = .seconds(1), resumeDelay: Duration = .zero,
    _ body: (ReplayRig) async throws -> Void
) async throws {
    try await withTemporaryDirectory { directory in
        let suite = "ReplayControllerTests-\(UUID().uuidString)"
        let defaults = try unwrap(UserDefaults(suiteName: suite), "a defaults suite")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.settings = RecorderSettings(selection: selection, replay: ReplayPreferences(enabled: enabled, seconds: seconds))
        let rig = ReplayRig(in: directory, store: store, probe: probe, pruneMargin: pruneMargin, resumeDelay: resumeDelay)
        do {
            try await body(rig)
        } catch {
            await rig.controller.shutDown()
            throw error
        }
        await rig.controller.shutDown()
    }
}

@MainActor private final class ReplayRig {
    nonisolated static let now = Date(timeIntervalSince1970: 1_794_773_523)
    static let displays = [
        DisplayInfo(id: 1, frame: Rect(x: 0, y: 0, width: 64, height: 36), scale: 1, isMain: true, maximumFramesPerSecond: 60),
        DisplayInfo(id: 2, frame: Rect(x: 64, y: 0, width: 64, height: 36), scale: 1, isMain: false, maximumFramesPerSecond: 60),
    ]

    let directory: URL
    let scratchRoot: URL
    let projects: URL
    let store: SettingsStore
    let probe: ReplayProbe
    let disk: FakeDisk
    let factory: FakeFactory
    let calls: ReplayCalls
    let saveGate: SaveGate
    let activity: AsyncStream<SystemActivity>.Continuation
    let environment: ReplayEnvironment
    let controller: ReplayController

    init(in directory: URL, store: SettingsStore, probe: ReplayProbe, pruneMargin: Duration, resumeDelay: Duration) {
        self.directory = directory
        let scratchRoot = directory.appending(path: "Replay", directoryHint: .isDirectory)
        let projects = directory.appending(path: "Projects", directoryHint: .isDirectory)
        self.scratchRoot = scratchRoot
        self.projects = projects
        self.store = store
        self.probe = probe
        let calls = ReplayCalls(pruneMargin: pruneMargin)
        self.calls = calls
        let (stream, continuation) = AsyncStream.makeStream(of: SystemActivity.self)
        activity = continuation
        let (disk, factory, saveGate) = (FakeDisk(), FakeFactory(), SaveGate())
        (self.disk, self.factory, self.saveGate) = (disk, factory, saveGate)
        let ids = Mutex(0)
        let context = EditContext(
            app: AppInfo(name: "Toma", version: "0.5.0"), cachesRoot: directory.appending(path: "Caches", directoryHint: .isDirectory),
            defaultStyle: .toma, now: { ReplayRig.now },
            makeID: { prefix in
                ids.withLock { count in
                    count += 1
                    return prefix + String(format: "%08x", count)
                }
            },
            styleDirectory: nil)
        let environment = ReplayEnvironment(
            scratchRoot: scratchRoot,
            projectsFolder: projects,
            namePrefix: "Replay",
            displays: { Self.displays },
            windowDisplay: { _ in nil },
            prepare: { selection, quick, granted, configuration in
                calls.prepared.append(ReplayCalls.Prepared(selection: selection, granted: granted, seconds: configuration.seconds))
                let plan = try TakePlanner.plan(selection, settings: quick, displays: Self.displays, granted: granted, factory: factory)
                // The screen starts once the start gate lets it.
                let gate = calls.startGate
                let sources = plan.sources.map { $0.kind == .display ? GatedStartSource($0, gate: gate) : $0 }
                let coordinator = ReplayCoordinator(
                    scratchRoot: scratchRoot, app: AppInfo(name: "Tests", version: "0"), sources: sources, input: plan.input,
                    diskMonitor: disk.monitor(volume: directory),
                    configuration: ReplayConfiguration(
                        seconds: configuration.seconds, segmentDuration: .seconds(1), pruneMargin: calls.pruneMargin))
                return PreparedReplay(
                    coordinator: coordinator, kinds: Dictionary(uniqueKeysWithValues: plan.sources.map { ($0.trackID, $0.kind) }),
                    load: calls.load ?? plan.load)
            },
            editContext: {
                await saveGate.pass()
                return context
            },
            systemActivity: { stream },
            didStart: { package, selection in calls.started.append(ReplayCalls.Started(package: package, selection: selection)) },
            now: { ReplayRig.now })
        self.environment = environment
        controller = ReplayController(probe: probe, environment: environment, store: store, resumeDelay: resumeDelay)
        controller.onSaved = { saved in calls.saved.append(saved) }
        controller.onHeldOff = { problem in calls.heldOff.append(problem) }
        controller.phaseChanged = { calls.phaseChanges += 1 }
    }

    var package: ProjectPackage { ReplayScratch.package(in: scratchRoot) }

    var scratchExists: Bool { FileManager.default.fileExists(atPath: package.url.path) }

    func scratchManifest() throws -> Manifest {
        try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
    }

    func scratchProjectID() throws -> String? { try scratchManifest().projectID }

    /// The working take's segments, of every track.
    func scratchSegments() throws -> [SegmentRecord] {
        try scratchManifest().takes.flatMap(\.tracks).flatMap(\.segments)
    }

    /// The camera's styles its working log noted, oldest first (the take's initial one is its record's, not an event).
    func scratchCameraStyles() throws -> [CameraStyle] {
        let take = package.takeDirectory(ReplayScratch.takeID)
        let names = try FileManager.default.contentsOfDirectory(atPath: take.path).filter { $0.hasPrefix("events-") }.sorted()
        var styles: [CameraStyle] = []
        for name in names {
            let text = try String(contentsOf: take.appending(path: name), encoding: .utf8)
            for line in text.split(separator: "\n") {
                guard let event = try? ProjectJSON.decoder().decode(InputEvent.self, from: Data(line.utf8)) else { continue }
                if case .cameraStyle(let style) = event.kind { styles.append(style) }
            }
        }
        return styles
    }

    /// The projects saved, by name.
    func savedProjects() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        return names.filter { $0.hasSuffix(".toma") }.sorted()
    }
}

/// What the rig's environment was asked for, and what it answers.
@MainActor private final class ReplayCalls {
    struct Prepared {
        var selection: CaptureSelection
        var granted: Set<PermissionKind>
        var seconds: Int
    }

    struct Started {
        var package: ProjectPackage
        var selection: CaptureSelection
    }

    let pruneMargin: Duration
    /// The load the next preparations say, instead of the plan's.
    var load: EncoderLoadVerdict?
    var prepared: [Prepared] = []
    var started: [Started] = []
    var saved: [SavedTake] = []
    var phaseChanges = 0
    /// The problems that held it off, as it told them.
    var heldOff: [ReplayController.Problem] = []
    /// What the screen's start waits for.
    let startGate = StartGate()

    init(pruneMargin: Duration) {
        self.pruneMargin = pruneMargin
    }
}

/// Holds whoever passes it while it is closed.
@MainActor private final class SaveGate {
    private var isClosed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    func close() {
        isClosed = true
    }

    func open() {
        isClosed = false
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func pass() async {
        arrivals += 1
        guard isClosed else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Holds the starts that pass it while it is closed; from any thread.
private final class StartGate: Sendable {
    private struct State {
        var isClosed = false
        var arrivals = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var arrivals: Int { state.withLock { $0.arrivals } }

    func close() {
        state.withLock { $0.isClosed = true }
    }

    func open() {
        let waiters = state.withLock { state in
            state.isClosed = false
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func pass() async {
        await withCheckedContinuation { continuation in
            let passes = state.withLock { state in
                state.arrivals += 1
                guard state.isClosed else { return true }
                state.waiters.append(continuation)
                return false
            }
            if passes { continuation.resume() }
        }
    }
}

/// `source`, whose start first passes `gate`.
private final class GatedStartSource: CaptureSource {
    private let source: any CaptureSource
    private let gate: StartGate

    init(_ source: any CaptureSource, gate: StartGate) {
        self.source = source
        self.gate = gate
    }

    var trackID: String { source.trackID }
    var kind: TrackKind { source.kind }
    var media: TrackMedia { source.media }
    var sourceInfo: TrackSource { source.sourceInfo }
    var activeDeviceUniqueID: String? { source.activeDeviceUniqueID }

    func start(on queue: DispatchSerialQueue, sink: any CaptureSink) async throws {
        await gate.pass()
        try await source.start(on: queue, sink: sink)
    }

    func stop() async {
        await source.stop()
    }
}

/// Every permission granted unless set otherwise; remembers what was asked for.
private final class ReplayProbe: PermissionProbe {
    private let states: Mutex<[PermissionKind: PermissionState]>
    private let asked = Mutex<[PermissionKind]>([])

    init(_ states: [PermissionKind: PermissionState] = [:]) {
        self.states = Mutex(states)
    }

    var requests: [PermissionKind] { asked.withLock { $0 } }

    func set(_ kind: PermissionKind, _ state: PermissionState) {
        states.withLock { $0[kind] = state }
    }

    func state(of kind: PermissionKind) -> PermissionState {
        states.withLock { $0[kind] } ?? .granted
    }

    func request(_ kind: PermissionKind) async -> PermissionState {
        asked.withLock { $0.append(kind) }
        return state(of: kind)
    }
}
