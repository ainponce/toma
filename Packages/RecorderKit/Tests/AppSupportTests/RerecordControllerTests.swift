// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Recording
import Synchronization
import Testing

/// "Re-record from Here" in the controller (plan 3d, Task T6; phase 3 design §8.2): a take recorded into the package the
/// editor has open, by a real coordinator recording synthetic sources, which never creates, trashes or removes a
/// project, and tells the editor once how it ended.
@MainActor @Suite(.serialized) struct RerecordControllerTests {
    @Test func rerecordRecordsIntoTheSamePackage() async throws {
        try await withRerecordRig { rig in
            let earlier = try treeHash(rig.package.takeDirectory("take-001"))
            rig.rerecord()
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            #expect(rig.controller.takePackageURL == rig.package.url)
            await rig.controller.stop(openingEditor: true)

            #expect(rig.creations == 0)
            #expect(rig.takes.packages == [rig.package])
            #expect(rig.takes.requests.map(\.target) == [rig.target])
            let manifest = try rig.manifest()
            #expect(manifest.takes.map(\.id) == ["take-001", "take-002"])
            #expect(manifest.takes.map(\.status) == [.complete, .complete])
            #expect(manifest.formatVersion == 5)  // two takes (design §11), in the coordinator's one write
            // The earlier take and the editor's files are as they were; nothing else is in the projects folder.
            #expect(try treeHash(rig.package.takeDirectory("take-001")) == earlier)
            #expect(try Data(contentsOf: rig.package.editURL) == RerecordRig.editorDocument)
            #expect(try rig.projectsOnDisk() == [rig.package.url.lastPathComponent])
        }
    }

    @Test(arguments: AfterStop.allCases) func rerecordEndsWithItsTakeAndNeverOpensAnEditor(afterStop: AfterStop) async throws {
        try await withRerecordRig(afterStop: afterStop) { rig in
            rig.rerecord()
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            rig.controller.stopRecording()
            #expect(await eventually { !rig.ends.isEmpty && rig.controller.phase == .idle })

            #expect(rig.ends == [RerecordRig.End(target: rig.target, outcome: .recorded(takeID: "take-002"))])
            #expect(rig.editorOpenings.isEmpty)
            let saved = try #require(rig.controller.lastSaved)
            // The editor comes back whatever "When Recording Stops" says (plan decision 10).
            #expect(saved.projectURL == rig.package.url && saved.openedEditor)
            #expect(rig.controller.lastProjectURL == rig.package.url)
            #expect(rig.controller.recordedThisSession(rig.package.url))
            #expect(rig.startFailures.isEmpty)
        }
    }

    @Test func restartOfARerecordKeepsTheTakeInThePackage() async throws {
        try await withRerecordRig { rig in
            rig.rerecord()
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            try await Task.sleep(for: .milliseconds(300))
            rig.controller.restartTake()
            #expect(await eventually { rig.takes.requests.count == 2 && rig.controller.phase.isRecordingATake })
            #expect(rig.ends.isEmpty)  // the re-record goes on
            await rig.controller.stop(openingEditor: true)

            #expect(rig.ends == [RerecordRig.End(target: rig.target, outcome: .recorded(takeID: "take-003"))])
            #expect(rig.takes.packages == [rig.package, rig.package])
            #expect(rig.takes.requests.map(\.target) == [rig.target, rig.target])
            // The restarted take stays in the package, unused: nothing went to the trash.
            #expect(try rig.manifest().takes.map(\.id) == ["take-001", "take-002", "take-003"])
            #expect(try rig.manifest().takes.map(\.status) == [.complete, .complete, .complete])
            #expect(!FileManager.default.fileExists(atPath: ProjectTrash.folder(in: rig.folder).path))
            #expect(!rig.confirmations.contains(.movedToTrash))
            #expect(rig.controller.notices.isEmpty)
            #expect(try rig.projectsOnDisk() == [rig.package.url.lastPathComponent])
            #expect(rig.creations == 0 && rig.editorOpenings.isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1))) func cancelledCountdownOfARerecordDeletesNothing() async throws {
        try await withRerecordRig(countdown: 3) { rig in
            let before = try treeHash(rig.package.url)
            rig.sleep.hold()
            rig.rerecord()
            #expect(await eventually { rig.sleep.calls == 1 })
            #expect(rig.controller.phase == .countingDown(remaining: 3))
            await rig.controller.stop(openingEditor: true)

            #expect(rig.ends == [RerecordRig.End(target: rig.target, outcome: .nothing)])
            #expect(rig.controller.phase == .idle)
            #expect(rig.confirmations == [.countdownCancelled])
            #expect(try treeHash(rig.package.url) == before)
            #expect(rig.takes.requests.isEmpty && rig.creations == 0)
            #expect(rig.controller.lastSaved == nil && rig.editorOpenings.isEmpty)
        }
    }

    enum FailedStart: CaseIterable {
        /// The take cannot be planned: its display is not connected.
        case plan
        /// The coordinator's start fails for the screen, which nothing records without.
        case screen
        /// A package of version 2, which no take is recorded into.
        case oldPackage
    }

    @Test(arguments: FailedStart.allCases) func failedStartOfARerecordNeverRemovesThePackage(failure: FailedStart) async throws {
        // A package with no take at all, which a new project's failed start would remove (`ProjectFolder.removeIfUnused`).
        try await withRerecordRig(fixture: failure == .oldPackage ? .version2 : .empty) { rig in
            let before = try treeHash(rig.package.url)
            var selection = CaptureSelection.mainDisplay(1)
            switch failure {
            case .plan: selection.displayIDs = [9]
            case .screen: rig.takes.factory.displayFailures = 99
            case .oldPackage: break
            }
            rig.rerecord(selection: selection)
            #expect(await eventually { !rig.ends.isEmpty })

            #expect(rig.ends == [RerecordRig.End(target: rig.target, outcome: .nothing)])
            #expect(rig.startFailures.count == 1)
            #expect(rig.controller.phase == .idle)
            #expect(FileManager.default.fileExists(atPath: rig.package.manifestURL.path))
            switch failure {
            case .plan, .oldPackage:
                #expect(try treeHash(rig.package.url) == before)
            case .screen:
                // What the coordinator closed is kept, as in any take.
                #expect(try rig.manifest().takes.map(\.id) == ["take-001"])
            }
            #expect(rig.creations == 0 && rig.editorOpenings.isEmpty)
            #expect(try rig.projectsOnDisk() == [rig.package.url.lastPathComponent])
        }
    }

    @Test func retryWithoutTheCameraStaysInThePackage() async throws {
        try await withRerecordRig { rig in
            rig.takes.factory.cameraFailures = 99
            var selection = CaptureSelection.mainDisplay(1)
            selection.camera = .systemDefault
            rig.rerecord(selection: selection)
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            #expect(rig.takes.requests.map(\.skipping) == [[], [.camera]])
            #expect(rig.takes.requests.map(\.target) == [rig.target, rig.target])
            #expect(rig.takes.packages == [rig.package, rig.package])
            #expect(rig.controller.notices == [.optionalSourceFailedToStart(.camera)])
            await rig.controller.stop(openingEditor: true)

            #expect(rig.ends == [RerecordRig.End(target: rig.target, outcome: .recorded(takeID: "take-003"))])
            // The attempt that failed is kept as it was closed.
            let takes = try rig.manifest().takes
            #expect(takes.map(\.id) == ["take-001", "take-002", "take-003"])
            #expect(takes.last?.tracks.map(\.kind) == [.display, .microphone])
            #expect(rig.creations == 0)
            #expect(try rig.projectsOnDisk() == [rig.package.url.lastPathComponent])
        }
    }

    @Test func quitDuringARerecordTellsQuit() async throws {
        try await withRerecordRig { rig in
            rig.rerecord()
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            await rig.controller.stop(openingEditor: false)

            #expect(rig.ends == [RerecordRig.End(target: rig.target, outcome: .quit)])
            #expect(rig.controller.lastSaved == nil && rig.editorOpenings.isEmpty)
            let takes = try rig.manifest().takes
            #expect(takes.map(\.id) == ["take-001", "take-002"])
        }
    }

    enum RerecordEnd: CaseIterable {
        case stopped, quit, diskFull, restartedThenStopped, countdownCancelled, screenDenied, screenLostDuringCountdown
        case planFailed, islandClosed, startedWhileRecording
    }

    @Test(.timeLimit(.minutes(1)), arguments: RerecordEnd.allCases) func everyWayARerecordEndsIsToldOnce(end: RerecordEnd) async throws {
        let countdown = [.countdownCancelled, .screenLostDuringCountdown].contains(end) ? 3 : 0
        try await withRerecordRig(countdown: countdown) { rig in
            let other = RerecordTarget(packageURL: rig.folder.appendingPathComponent("Other.toma", isDirectory: true))
            var expected = [RerecordRig.End(target: rig.target, outcome: .nothing)]
            switch end {
            case .stopped, .quit, .diskFull, .restartedThenStopped, .startedWhileRecording:
                rig.rerecord()
                #expect(await eventually { rig.controller.phase.isRecordingATake })
                switch end {
                case .stopped:
                    await rig.controller.stop(openingEditor: true)
                    expected = [RerecordRig.End(target: rig.target, outcome: .recorded(takeID: "take-002"))]
                case .quit:
                    await rig.controller.stop(openingEditor: false)
                    expected = [RerecordRig.End(target: rig.target, outcome: .quit)]
                case .diskFull:
                    rig.disk.set(importantUsage: 9_000_000_000, available: 500_000_000)
                    #expect(await eventually { rig.controller.phase == .idle && !rig.ends.isEmpty })
                    #expect(rig.controller.notices.contains(.stoppedForDiskSpace))
                    expected = [RerecordRig.End(target: rig.target, outcome: .recorded(takeID: "take-002"))]
                case .restartedThenStopped:
                    rig.controller.restartTake()
                    #expect(await eventually { rig.takes.requests.count == 2 && rig.controller.phase.isRecordingATake })
                    await rig.controller.stop(openingEditor: true)
                    expected = [RerecordRig.End(target: rig.target, outcome: .recorded(takeID: "take-003"))]
                case .startedWhileRecording:
                    // A second re-record cannot start while a take records: it ends at once, and the first goes on.
                    rig.controller.startRerecord(
                        into: other, selection: .mainDisplay(1), settings: QuickSettings(), cameraStyle: .default)
                    #expect(rig.ends == [RerecordRig.End(target: other, outcome: .nothing)])
                    #expect(rig.controller.phase.isRecordingATake)
                    await rig.controller.stop(openingEditor: true)
                    expected = [
                        RerecordRig.End(target: other, outcome: .nothing),
                        RerecordRig.End(target: rig.target, outcome: .recorded(takeID: "take-002")),
                    ]
                default:
                    Issue.record("not a take that records")
                }
            case .countdownCancelled:
                rig.sleep.hold()
                rig.rerecord()
                #expect(await eventually { rig.sleep.calls == 1 })
                await rig.controller.stop(openingEditor: true)
            case .screenDenied:
                rig.probe.setScreenRecording(.denied)
                rig.rerecord()
                #expect(rig.onboardingOpenings == 1)
            case .screenLostDuringCountdown:
                rig.sleep.hold()
                rig.rerecord()
                #expect(await eventually { rig.sleep.calls == 1 })
                rig.probe.setScreenRecording(.denied)
                rig.sleep.release()
                #expect(await eventually { rig.onboardingOpenings == 1 })
            case .planFailed:
                rig.rerecord(selection: .mainDisplay(9))
            case .islandClosed:
                // The island asked for a source that was missing, and was closed without recording.
                rig.controller.cancelRerecord(rig.target)
            }
            #expect(await eventually { rig.ends.count == expected.count && rig.controller.phase == .idle })
            // Nothing more comes, also once the hooks and the take's warnings have ended.
            try await Task.sleep(for: .milliseconds(300))
            #expect(rig.ends == expected)
            #expect(rig.editorOpenings.isEmpty && rig.creations == 0)
        }
    }

    /// A re-record in progress tells its own end, once: asking for it again, or cancelling its island, neither ends it nor
    /// tells anything.
    @Test func aRerecordInProgressTellsOnlyItsOwnEnd() async throws {
        try await withRerecordRig { rig in
            rig.rerecord()
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            rig.rerecord()
            rig.controller.cancelRerecord(rig.target)
            #expect(rig.ends.isEmpty && rig.controller.phase.isRecordingATake)
            #expect(rig.takes.requests.count == 1)
            await rig.controller.stop(openingEditor: true)
            #expect(rig.ends == [RerecordRig.End(target: rig.target, outcome: .recorded(takeID: "take-002"))])
        }
    }

    @Test(arguments: [true, false]) func scriptIsSavedWhenTheTakeStarts(rerecording: Bool) async throws {
        try await withRerecordRig(countdown: 3) { rig in
            var asked: [RerecordTarget?] = []
            rig.controller.scriptToSave = { target in
                asked.append(target)
                return "Hola"
            }
            rig.sleep.hold()
            if rerecording {
                rig.rerecord()
            } else {
                rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            }
            #expect(await eventually { rig.sleep.calls == 1 })
            // Not while counting down: once the take records.
            #expect(asked.isEmpty)
            rig.sleep.release()
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            let package = try #require(rig.takes.packages.first)
            #expect(package == rig.package || !rerecording)
            #expect(await eventually { package.readScript() == "Hola" })
            // Asked for the take's target: the re-record's, or none.
            #expect(asked == [rerecording ? rig.target : nil])
            await rig.controller.stop(openingEditor: true)
            #expect(package.readScript() == "Hola")
        }
    }

    @Test(arguments: [nil, ""]) func withoutAScriptNothingIsWritten(script: String?) async throws {
        try await withRerecordRig { rig in
            rig.controller.scriptToSave = { _ in script }
            rig.rerecord()
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            await rig.controller.stop(openingEditor: true)
            #expect(!FileManager.default.fileExists(atPath: rig.package.scriptURL.path))
            #expect(rig.package.readScript() == nil)
        }
    }

    /// Decision 11: during a re-record the teleprompter owns the project's script, so the start of its take never replaces
    /// it, whatever the script it is asked for is (the settings' one, say).
    @Test func aRerecordNeverReplacesTheProjectsScript() async throws {
        try await withRerecordRig { rig in
            try rig.package.writeScript("Guion del proyecto")
            var asked: [RerecordTarget?] = []
            rig.controller.scriptToSave = { target in
                asked.append(target)
                return "Guion de los ajustes"
            }
            rig.rerecord()
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            await rig.controller.stop(openingEditor: true)

            #expect(asked == [rig.target])
            #expect(rig.package.readScript() == "Guion del proyecto")
        }
    }

    /// A target recomputed by the editor (another word of the script, another form of the URL, the URL after the package
    /// was renamed) names the same re-record: it neither ends it twice nor starts another.
    @Test(.timeLimit(.minutes(1))) func aRecomputedTargetIsTheSameRerecord() async throws {
        try await withRerecordRig(countdown: 3) { rig in
            rig.rerecord()
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            let elsewhere = rig.folder.appendingPathComponent("../projects/Edited.toma/", isDirectory: true)
            let recomputed = RerecordTarget(packageURL: elsewhere, scriptWord: 3)
            #expect(recomputed != rig.target)
            rig.controller.startRerecord(into: recomputed, selection: .mainDisplay(1), settings: QuickSettings(), cameraStyle: .default)
            rig.controller.cancelRerecord(recomputed)
            #expect(rig.ends.isEmpty && rig.controller.phase.isRecordingATake && rig.takes.requests.count == 1)
            await rig.controller.stop(openingEditor: true)
            #expect(rig.ends == [RerecordRig.End(target: rig.target, outcome: .recorded(takeID: "take-002"))])

            // Renamed while it counts down: the island's cancel, with the URL the editor has now, cancels it.
            rig.sleep.hold()
            rig.rerecord()
            #expect(await eventually { rig.sleep.calls == 4 })
            let renamed = rig.folder.appendingPathComponent("Renamed.toma", isDirectory: true)
            try FileManager.default.moveItem(at: rig.package.url, to: renamed)
            rig.controller.cancelRerecord(RerecordTarget(packageURL: renamed, scriptWord: 7))
            #expect(await eventually { rig.ends.count == 2 && rig.controller.phase == .idle })
            try await Task.sleep(for: .milliseconds(300))
            #expect(rig.ends.last == RerecordRig.End(target: rig.target, outcome: .nothing))
            #expect(rig.ends.count == 2 && rig.takes.requests.count == 1)
        }
    }

    /// The island's cancel before the re-record records: nothing of it is used, and it ends once as `.nothing`.
    enum CancelPoint: CaseIterable {
        /// While it counts down: nothing is recorded.
        case countdown
        /// While its take starts: the take is closed and stays in the package, unused.
        case starting
    }

    @Test(.timeLimit(.minutes(1)), arguments: CancelPoint.allCases) func cancelBeforeItRecordsEndsWithNothing(point: CancelPoint) async throws {
        try await withRerecordRig(countdown: point == .countdown ? 3 : 0) { rig in
            let before = try treeHash(rig.package.url)
            switch point {
            case .countdown:
                rig.sleep.hold()
                rig.rerecord()
                #expect(await eventually { rig.sleep.calls == 1 })
            case .starting:
                rig.takes.startGate.close()
                rig.rerecord()
                #expect(await eventually { rig.takes.startGate.arrivals == 1 })
                #expect(rig.controller.phase == .starting)
            }
            rig.controller.cancelRerecord(rig.target)
            if point == .starting {
                await settle()
                rig.takes.startGate.open()
            }
            #expect(await eventually { !rig.ends.isEmpty && rig.controller.phase == .idle })
            try await Task.sleep(for: .milliseconds(300))

            #expect(rig.ends == [RerecordRig.End(target: rig.target, outcome: .nothing)])
            #expect(rig.controller.lastSaved == nil && rig.editorOpenings.isEmpty)
            switch point {
            case .countdown:
                #expect(try treeHash(rig.package.url) == before)
                #expect(rig.takes.requests.isEmpty)
            case .starting:
                let takes = try rig.manifest().takes
                #expect(takes.map(\.id) == ["take-001", "take-002"])
                #expect(takes.map(\.status) == [.complete, .complete])
            }
            #expect(!FileManager.default.fileExists(atPath: ProjectTrash.folder(in: rig.folder).path))
        }
    }

    /// A stop that comes while the take starts closes it (`.handedToStop`): the take if it started, nothing if its start
    /// failed; once, and nothing is removed.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func aStopWhileTheTakeStartsEndsOnce(startFails: Bool) async throws {
        try await withRerecordRig { rig in
            if startFails { rig.takes.factory.displayFailures = 99 }
            rig.takes.startGate.close()
            rig.rerecord()
            #expect(await eventually { rig.takes.startGate.arrivals == 1 })
            let stopping = Task { await rig.controller.stop(openingEditor: true) }
            await settle()
            rig.takes.startGate.open()
            await stopping.value
            try await Task.sleep(for: .milliseconds(300))

            #expect(rig.ends == [RerecordRig.End(target: rig.target, outcome: startFails ? .nothing : .recorded(takeID: "take-002"))])
            #expect(rig.controller.phase == .idle)
            #expect(rig.startFailures.isEmpty)  // the stop came first: no failure to say
            #expect(try rig.manifest().takes.map(\.id) == ["take-001", "take-002"])
            #expect(try rig.projectsOnDisk() == [rig.package.url.lastPathComponent])
        }
    }

    /// A stop (or a quit) that comes while a restart closes the take ends the re-record with that take, once: no new take
    /// starts, and nothing goes to the trash.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func aStopDuringARestartEndsWithTheTake(quitting: Bool) async throws {
        try await withRerecordRig { rig in
            rig.rerecord()
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            rig.takes.stopGate.close()
            rig.controller.restartTake()
            #expect(await eventually { rig.takes.stopGate.arrivals == 1 })
            let stopping = Task { await rig.controller.stop(openingEditor: !quitting) }
            await settle()
            rig.takes.stopGate.open()
            await stopping.value
            try await Task.sleep(for: .milliseconds(300))

            #expect(rig.ends == [RerecordRig.End(target: rig.target, outcome: quitting ? .quit : .recorded(takeID: "take-002"))])
            #expect(rig.controller.phase == .idle && rig.takes.requests.count == 1)
            #expect(try rig.manifest().takes.map(\.id) == ["take-001", "take-002"])
            #expect(!FileManager.default.fileExists(atPath: ProjectTrash.folder(in: rig.folder).path))
            #expect(!rig.confirmations.contains(.movedToTrash))
        }
    }

    enum RestartEnd: CaseIterable {
        /// The new take's start fails for the screen.
        case newTakeFails
        /// The new take's countdown is stopped.
        case countdownStopped
        /// The island's cancel, in the new take's countdown.
        case countdownCancelled
    }

    /// A restart whose new take never records ends the re-record once, as `.nothing`: the restarted take stays in the
    /// package, unused.
    @Test(.timeLimit(.minutes(1)), arguments: RestartEnd.allCases) func aRestartWithoutANewTakeEndsWithNothing(end: RestartEnd) async throws {
        try await withRerecordRig(countdown: end == .newTakeFails ? 0 : 3) { rig in
            rig.rerecord()
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            switch end {
            case .newTakeFails:
                rig.takes.factory.displayFailures = 99
                rig.controller.restartTake()
            case .countdownStopped, .countdownCancelled:
                rig.sleep.hold()
                rig.controller.restartTake()
                #expect(await eventually { rig.sleep.calls == 4 })  // the new take's first second
                if end == .countdownStopped {
                    await rig.controller.stop(openingEditor: true)
                } else {
                    rig.controller.cancelRerecord(rig.target)
                }
            }
            #expect(await eventually { !rig.ends.isEmpty && rig.controller.phase == .idle })
            try await Task.sleep(for: .milliseconds(300))

            #expect(rig.ends == [RerecordRig.End(target: rig.target, outcome: .nothing)])
            #expect(rig.startFailures.count == (end == .newTakeFails ? 1 : 0))
            let takes = try rig.manifest().takes
            // The new take's failed start is kept as the coordinator closed it.
            #expect(takes.map(\.id) == (end == .newTakeFails ? ["take-001", "take-002", "take-003"] : ["take-001", "take-002"]))
            #expect(!FileManager.default.fileExists(atPath: ProjectTrash.folder(in: rig.folder).path))
            #expect(try rig.projectsOnDisk() == [rig.package.url.lastPathComponent])
            #expect(rig.creations == 0 && rig.editorOpenings.isEmpty)
        }
    }

    @Test func aTakeWithoutTargetIsAsToday() async throws {
        try await withRerecordRig { rig in
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            let first = try #require(rig.takes.packages.first)
            #expect(first != rig.package && rig.takes.requests.map(\.target) == [nil])
            try await Task.sleep(for: .milliseconds(300))
            // A restart trashes its project, and records the next take in a new one.
            rig.controller.restartTake()
            #expect(await eventually { rig.takes.packages.count == 2 && rig.controller.phase.isRecordingATake })
            #expect(try FileManager.default.contentsOfDirectory(atPath: ProjectTrash.folder(in: rig.folder).path)
                == [first.url.lastPathComponent])
            #expect(rig.confirmations == [.movedToTrash])
            await rig.controller.stop(openingEditor: true)

            let second = try #require(rig.takes.packages.last)
            #expect(rig.creations == 2)
            #expect(rig.editorOpenings.map(\.package) == [second.url] && rig.editorOpenings.map(\.take) == ["take-001"])
            #expect(rig.controller.lastSaved?.openedEditor == true)
            #expect(rig.ends.isEmpty)
            // The edited project was never touched.
            #expect(try rig.manifest().takes.map(\.id) == ["take-001"])
        }
    }
}

extension RecordingController.Phase {
    fileprivate var isRecordingATake: Bool {
        if case .recording = self { true } else { false }
    }
}

/// Lets the main-actor jobs already queued (a stop just asked for) run up to their next wait.
@MainActor private func settle() async {
    for _ in 0..<10 { await Task.yield() }
}

/// A controller whose takes are recorded with its own defaults, `countdown` seconds of countdown (each a wait of
/// `RerecordRig.sleep`) and `afterStop`, next to the package of `fixture` that an editor would have open.
@MainActor private func withRerecordRig(
    countdown: Int = 0, afterStop: AfterStop = .openEditor, fixture: RerecordRig.Fixture = .oneTake,
    _ body: (RerecordRig) async throws -> Void
) async throws {
    try await withTemporaryDirectory { directory in
        let suite = "RerecordControllerTests-\(UUID().uuidString)"
        let defaults = try unwrap(UserDefaults(suiteName: suite), "a defaults suite")
        defer { defaults.removePersistentDomain(forName: suite) }
        SettingsStore(defaults: defaults).settings = RecorderSettings(countdownSeconds: countdown, afterStop: afterStop)
        try await body(RerecordRig(in: directory, defaults: defaults, fixture: fixture))
    }
}

/// A `RecordingController` recording into `projects/` of a test folder, which already holds `Edited.toma`, the package
/// an editor has open, as `fixture` says; with a record of what the controller asked for and told.
@MainActor private final class RerecordRig {
    enum Fixture {
        /// `take-001`, written as the recorder does, and the editor's `edit.json`.
        case oneTake
        /// A manifest without a take and an empty `takes/`: what `ProjectFolder.removeIfUnused` would delete.
        case empty
        /// An empty package of version 2, which no take is recorded into.
        case version2
    }

    struct End: Equatable {
        var target: RerecordTarget
        var outcome: RerecordOutcome
    }

    struct EditorOpening {
        var package: URL
        var take: String?
    }

    /// The bytes of the fixture's `edit.json`: the controller never writes it.
    static let editorDocument = Data(#"{"editor":"document"}"#.utf8)

    let folder: URL
    let package: ProjectPackage
    let target: RerecordTarget
    let probe = ScreenProbe()
    let disk = FakeDisk()
    let sleep = HeldSleep()
    let takes: Takes
    let controller: RecordingController
    private let createdPackages = Counter()
    private(set) var ends: [End] = []
    private(set) var editorOpenings: [EditorOpening] = []
    private(set) var startFailures: [any Error] = []
    private(set) var confirmations: [IslandConfirmation] = []
    private(set) var onboardingOpenings = 0

    /// How many new projects the controller made.
    var creations: Int { createdPackages.value }

    init(in directory: URL, defaults: UserDefaults, fixture: Fixture) throws {
        let folder = directory.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch fixture {
        case .oneTake:
            let builder = try TakeBuilder(in: folder, name: "Edited")
            package = try builder.write().package
            try Self.editorDocument.write(to: package.editURL)
        case .empty:
            package = try TakeBuilder(in: folder, name: "Edited").package
        case .version2:
            package = try TakeBuilder(in: folder, name: "Edited", formatVersion: 2).package
        }
        self.folder = folder
        target = RerecordTarget(packageURL: package.url, scriptWord: 12)
        let takes = Takes(disk: disk)
        self.takes = takes
        let created = createdPackages
        let sleep = sleep
        let environment = TakeEnvironment(
            projectsFolder: folder,
            app: AppInfo(name: "Tests", version: "0"),
            projectNamePrefix: "Recording",
            hasMicrophone: { true },
            createPackage: { folder, prefix, app, now in
                created.increment()
                return try ProjectFolder.createPackage(in: folder, prefix: prefix, app: app, now: now)
            },
            prepareTake: { package, request, granted in try takes.prepare(package, request, granted) },
            termination: NoTerminationGuard(),
            now: { Date() },
            sleep: { duration in try await sleep.sleep(duration) })
        controller = RecordingController(probe: probe, environment: environment, defaults: defaults)
        controller.rerecordEnded = { [weak self] target, outcome in self?.ends.append(End(target: target, outcome: outcome)) }
        controller.openEditor = { [weak self] url, take in self?.editorOpenings.append(EditorOpening(package: url, take: take)) }
        controller.showStartFailure = { [weak self] error in self?.startFailures.append(error) }
        controller.onConfirmation = { [weak self] confirmation in self?.confirmations.append(confirmation) }
        controller.openOnboarding = { [weak self] in self?.onboardingOpenings += 1 }
    }

    /// Re-records into the fixture `selection` (the main display and the default microphone unless given).
    func rerecord(selection: CaptureSelection = .mainDisplay(1)) {
        controller.startRerecord(into: target, selection: selection, settings: QuickSettings(), cameraStyle: .default)
    }

    func manifest() throws -> Manifest {
        try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
    }

    /// The names of what the projects folder holds.
    func projectsOnDisk() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }
}

/// What `prepareTake` was asked for, and the plans it made: `TakePlanner`'s of the request with displays 1 (the main
/// one) and 2 connected and `factory`'s synthetic sources, each recorded by a coordinator of its own behind `startGate`
/// and `stopGate` (open unless the test closes them).
@MainActor private final class Takes {
    private static let displays = [
        DisplayInfo(id: 1, frame: Rect(x: 0, y: 0, width: 64, height: 36), scale: 1, isMain: true, maximumFramesPerSecond: 60),
        DisplayInfo(id: 2, frame: Rect(x: 64, y: 0, width: 64, height: 36), scale: 1, isMain: false, maximumFramesPerSecond: 60),
    ]

    let factory = FakeFactory()
    /// Passed by every take's `start()` before the coordinator's.
    let startGate = Gate()
    /// Passed by every take's `stop()` before the coordinator's.
    let stopGate = Gate()
    private(set) var requests: [TakeRequest] = []
    private(set) var packages: [ProjectPackage] = []
    private let disk: FakeDisk

    init(disk: FakeDisk) {
        self.disk = disk
    }

    func prepare(_ package: ProjectPackage, _ request: TakeRequest, _ granted: Set<PermissionKind>) throws -> PreparedTake {
        requests.append(request)
        packages.append(package)
        let plan = try TakePlanner.plan(
            request.selection, settings: request.settings, displays: Self.displays, granted: granted, skipping: request.skipping,
            includedWindowIDs: request.includedWindowIDs, factory: factory)
        let coordinator = RecordingCoordinator(
            package: package, sources: plan.sources, input: plan.input, diskMonitor: disk.monitor(volume: package.url),
            systemActivity: AsyncStream { $0.finish() }, cameraStyle: request.cameraStyle)
        return PreparedTake(
            recording: GatedRecording(coordinator: coordinator, startGate: startGate, stopGate: stopGate), optional: plan.optional,
            kinds: Dictionary(uniqueKeysWithValues: plan.sources.map { ($0.trackID, $0.kind) }), load: plan.load,
            microphoneMeter: plan.microphoneMeter)
    }
}

/// A coordinator whose `start()` and `stop()` first pass a gate the test holds.
private final class GatedRecording: TakeRecording {
    let coordinator: RecordingCoordinator
    private let startGate: Gate
    private let stopGate: Gate

    var warnings: AsyncStream<RecordingWarning> { coordinator.warnings }

    init(coordinator: RecordingCoordinator, startGate: Gate, stopGate: Gate) {
        self.coordinator = coordinator
        self.startGate = startGate
        self.stopGate = stopGate
    }

    func setOnAutoStop(_ handler: @escaping @Sendable (TakeRecord, (any Error)?) -> Void) async {
        await coordinator.setOnAutoStop(handler)
    }

    func start() async throws -> String {
        await startGate.pass()
        return try await coordinator.start()
    }

    func stop() async throws -> TakeRecord {
        await stopGate.pass()
        return try await coordinator.stop()
    }

    func pause() async throws {
        try await coordinator.pause()
    }

    func resume() async throws {
        try await coordinator.resume()
    }

    func addMarker() async throws -> HostTime {
        try await coordinator.addMarker()
    }

    func setCameraStyle(_ style: CameraStyle) async throws {
        try await coordinator.setCameraStyle(style)
    }
}

/// Holds whoever passes it while it is closed, and counts who came.
private final class Gate: Sendable {
    private let state = Mutex((isOpen: true, arrivals: 0, waiting: [CheckedContinuation<Void, Never>]()))

    var arrivals: Int { state.withLock { $0.arrivals } }

    func close() {
        state.withLock { $0.isOpen = false }
    }

    func open() {
        let waiting = state.withLock { state in
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    func pass() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state in
                state.arrivals += 1
                if !state.isOpen { state.waiting.append(continuation) }
                return state.isOpen
            }
            if isOpen { continuation.resume() }
        }
    }
}

/// Every permission granted but screen recording, which the test sets (granted unless it says otherwise).
private final class ScreenProbe: PermissionProbe {
    private let screen = Mutex(PermissionState.granted)

    func setScreenRecording(_ state: PermissionState) {
        screen.withLock { $0 = state }
    }

    func state(of kind: PermissionKind) -> PermissionState {
        kind == .screenRecording ? screen.withLock { $0 } : .granted
    }

    func request(_ kind: PermissionKind) async -> PermissionState {
        state(of: kind)
    }
}

/// The countdown's `sleep`: returns at once unless held, then waits until `release()` or its task is cancelled (a stop
/// during the countdown), throwing `CancellationError` as `Task.sleep` does.
private final class HeldSleep: Sendable {
    private let state = Mutex((calls: 0, holding: false))

    /// How many waits were asked for.
    var calls: Int { state.withLock { $0.calls } }

    func hold() {
        state.withLock { $0.holding = true }
    }

    func release() {
        state.withLock { $0.holding = false }
    }

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        state.withLock { $0.calls += 1 }
        while state.withLock({ $0.holding }) {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Counts, from any thread.
private final class Counter: Sendable {
    private let count = Mutex(0)

    var value: Int { count.withLock { $0 } }

    func increment() {
        count.withLock { $0 += 1 }
    }
}

private struct NoTerminationGuard: TerminationGuarding {
    func takeBegan() {}
    func takeEnded() {}
}
