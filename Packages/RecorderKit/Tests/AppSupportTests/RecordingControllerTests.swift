// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Dispatch
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Recording
import Synchronization
import Testing

/// Where a start waits, and so where a stop can come.
enum AwaitPoint: CaseIterable {
    /// The system asks for the microphone.
    case microphonePrompt
    /// The project is being created.
    case packageCreation
    /// The take's `start()`.
    case coordinatorStart
    /// A first stop's `close()` waits for the take's `start()`.
    case closingStart
    /// A first stop's `close()` waits for the take's `stop()`.
    case coordinatorStop
}

/// Takes of real coordinators recording synthetic sources, each started and stopped as the app does.
@MainActor @Suite(.serialized) struct RecordingControllerTests {
    @Test(arguments: AwaitPoint.allCases) func stopAtEachAwaitPoint(point: AwaitPoint) async throws {
        try await withRig(microphone: .notDetermined) { rig in
            let gate = switch point {
            case .microphonePrompt: rig.probe.gate
            case .packageCreation: rig.creation
            case .coordinatorStart, .closingStart: rig.startGate
            case .coordinatorStop: rig.stopGate
            }
            gate.close()
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())

            switch point {
            case .microphonePrompt, .packageCreation, .coordinatorStart:
                #expect(await eventually { gate.arrivals == 1 })
                let stopping = Task { await rig.controller.stop(openingEditor: true) }
                await settle()
                gate.open()
                await stopping.value
            case .closingStart:
                #expect(await eventually { gate.arrivals == 1 })
                let first = Task { await rig.controller.stop(openingEditor: true) }
                #expect(await eventually { rig.controller.phase == .stopping })
                let second = Task { await rig.controller.stop(openingEditor: true) }
                await settle()
                gate.open()
                await first.value
                await second.value
            case .coordinatorStop:
                #expect(await eventually { rig.controller.phase.isRecordingATake })
                let first = Task { await rig.controller.stop(openingEditor: true) }
                #expect(await eventually { gate.arrivals == 1 })
                let second = Task { await rig.controller.stop(openingEditor: true) }
                await settle()
                gate.open()
                await first.value
                await second.value
            }

            #expect(rig.controller.phase == .idle)
            #expect(rig.termination.began == rig.termination.ended)
            let packages = try rig.packagesOnDisk()
            switch point {
            case .microphonePrompt, .packageCreation:
                #expect(packages.isEmpty)
                #expect(rig.editorOpenings.isEmpty)
            case .coordinatorStart, .closingStart, .coordinatorStop:
                try #require(packages.count == 1)
                let takes = try rig.takesOnDisk(packages[0])
                #expect(takes.count == 1 && takes.first?.status == .complete)
                #expect(rig.editorOpenings.map(\.package.lastPathComponent) == [packages[0].lastPathComponent])
                #expect(rig.editorOpenings.map(\.take) == takes.map { Optional($0.id) })
            }
            #expect(rig.startFailures.isEmpty)
        }
    }

    @Test func microphoneFailureRetriesOnceWithoutMicrophone() async throws {
        try await withRig { rig in
            rig.takes.factory.microphoneFailures = 99
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            var withoutMicrophone = CaptureSelection.mainDisplay(1)
            withoutMicrophone.microphone = .off
            #expect(rig.takes.requests == [
                TakeRequest(selection: .mainDisplay(1), settings: QuickSettings()),
                TakeRequest(selection: withoutMicrophone, settings: QuickSettings()),
            ])
            #expect(rig.controller.notices.contains(.microphoneFailedToStart))
            #expect(!rig.controller.recordsMicrophone)
            await rig.controller.stop(openingEditor: true)

            #expect(rig.controller.phase == .idle)
            #expect(try rig.packagesOnDisk().count == 2)  // the failed project is left as it is
            let second = try #require(rig.takes.packages.last)
            let take = try #require(try rig.takesOnDisk(second.url).first)
            #expect(take.status == .complete)
            #expect(take.tracks.map(\.kind) == [.display])
            #expect(rig.editorOpenings.map(\.package.lastPathComponent) == [second.url.lastPathComponent])
            #expect(rig.startFailures.isEmpty)
            #expect(rig.termination.began == 2 && rig.termination.ended == 2)
        }
    }

    @Test func cameraOnRecordsWithoutCameraAndSaysSo() async throws {
        try await withRig { rig in
            var selection = CaptureSelection.mainDisplay(1)
            selection.camera = .systemDefault
            rig.controller.startRecording(selection: selection, settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            #expect(rig.controller.notices.contains(.cameraNotRecordedYet))
            #expect(rig.controller.recordsMicrophone)
            await rig.controller.stop(openingEditor: false)
            #expect(!rig.controller.recordsMicrophone)  // no take

            let package = try #require(rig.takes.packages.first)
            let take = try #require(try rig.takesOnDisk(package.url).first)
            #expect(take.status == .complete && take.tracks.map(\.kind) == [.display, .microphone])
            #expect(rig.takes.grants == [[.screenRecording, .microphone]])
            #expect(rig.takes.factory.calls == [
                .display(id: 1, framesPerSecond: 60, scale: .native), .microphone(.systemDefault), .input(displayIDs: [1]),
            ])
            #expect(rig.startFailures.isEmpty)
        }
    }

    /// With a microphone that was never allowed, and without one.
    @Test(arguments: [true, false]) func microphoneOffIsNeverRequested(hasMicrophone: Bool) async throws {
        try await withRig(microphone: .notDetermined, hasMicrophone: hasMicrophone) { rig in
            var selection = CaptureSelection.mainDisplay(1)
            selection.microphone = .off
            rig.controller.startRecording(selection: selection, settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            #expect(!rig.controller.recordsMicrophone)
            await rig.controller.stop(openingEditor: false)

            #expect(rig.probe.requests.isEmpty)
            #expect(!rig.controller.notices.contains(.noMicrophone) && !rig.controller.notices.contains(.microphoneAccessOff))
            #expect(!rig.controller.notices.contains(.cameraNotRecordedYet))
            #expect(rig.takes.grants == [[.screenRecording]])
            let package = try #require(rig.takes.packages.first)
            let take = try #require(try rig.takesOnDisk(package.url).first)
            #expect(take.status == .complete && take.tracks.map(\.kind) == [.display])
            #expect(rig.startFailures.isEmpty)
        }
    }

    @Test func planFailureLeavesNoPackage() async throws {
        // Without a microphone and with the camera on: the start has something to say about the take.
        try await withRig(hasMicrophone: false) { rig in
            var selection = CaptureSelection.mainDisplay(9)
            selection.camera = .systemDefault
            rig.controller.startRecording(selection: selection, settings: QuickSettings())
            #expect(await eventually { !rig.startFailures.isEmpty })

            #expect(rig.startFailures.map { $0 as? TakePlanError } == [.displayNotFound(9)])
            #expect(rig.controller.phase == .idle)
            #expect(rig.controller.notices.isEmpty)  // about a take that was not recorded
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: rig.folder.path)
            #expect(leftovers.isEmpty)
            #expect(rig.takes.requests.count == 1 && rig.takes.recordings.isEmpty)
            #expect(rig.termination.began == rig.termination.ended)
            #expect(rig.editorOpenings.isEmpty)
        }
    }

    @Test func diskAutoStopRacingUserStopOpensEditorOnce() async throws {
        try await withRig { rig in
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            rig.disk.set(importantUsage: 9_000_000_000, available: 500_000_000)
            // The disk has won: the take is closing on its own when the user stops it.
            #expect(await eventually { rig.controller.notices.contains(.stoppedForDiskSpace) })
            rig.controller.stopRecording()
            #expect(await eventually { rig.controller.phase == .idle })
            let recording = try #require(rig.takes.recordings.first)
            #expect(await eventually { recording.autoStops == 1 })
            try await Task.sleep(for: .milliseconds(100))  // the stop the automatic one asks for has run too

            #expect(rig.editorOpenings.count == 1)
            let package = try #require(rig.takes.packages.first)
            let take = try #require(try rig.takesOnDisk(package.url).first)
            #expect(take.status == .complete)
            let reasons = take.tracks.flatMap { $0.segments.map(\.endReason) }
            #expect(!reasons.isEmpty && reasons.allSatisfy { $0 == .diskFull })
            #expect(rig.termination.began == 1 && rig.termination.ended == 1)
        }
    }

    @Test func lateAutoStopOfAPreviousTakeLeavesTheNextTakeRecording() async throws {
        try await withRig { rig in
            // The first take's auto-stop handler runs only once the next take is recording.
            rig.autoStopGate.close()
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            rig.disk.set(importantUsage: 9_000_000_000, available: 500_000_000)
            #expect(await eventually { rig.controller.notices.contains(.stoppedForDiskSpace) })
            await rig.controller.stop(openingEditor: true)
            #expect(rig.controller.phase == .idle)

            rig.disk.set(importantUsage: 100_000_000_000, available: 100_000_000_000)
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            rig.autoStopGate.open()
            let first = try #require(rig.takes.recordings.first)
            #expect(await eventually { first.autoStops == 1 })
            try await Task.sleep(for: .milliseconds(100))  // a stop the late handler asked for would have run

            #expect(rig.controller.phase.isRecordingATake)
            let second = try #require(rig.takes.packages.last)
            #expect(try rig.takesOnDisk(second.url).map(\.status) == [.recording])
            #expect(rig.editorOpenings.count == 1)
            await rig.controller.stop(openingEditor: true)
            #expect(rig.editorOpenings.map(\.package.lastPathComponent).last == second.url.lastPathComponent)
            #expect(rig.termination.began == 2 && rig.termination.ended == 2)
        }
    }

    @Test func elapsedExcludesUserPause() async throws {
        try await withRig { rig in
            let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
            rig.now.set(start)
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase == .recording(since: start) })

            rig.now.set(start + 10)
            rig.controller.togglePause()
            #expect(rig.controller.isUserPaused)
            // The time stops with the coordinator's `paused`, not with `togglePause`.
            #expect(await eventually { rig.controller.elapsed(at: start + 100) == .seconds(10) })
            #expect(!rig.controller.isPaused)  // only the system's pauses
            rig.now.set(start + 15)
            rig.controller.togglePause()
            #expect(!rig.controller.isUserPaused)
            #expect(await eventually { rig.controller.elapsed(at: start + 18) == .seconds(13) })
            await rig.controller.stop(openingEditor: false)

            let package = try #require(rig.takes.packages.first)
            let take = try #require(try rig.takesOnDisk(package.url).first)
            let kinds = try EventLogReader.read(package.eventsURL(take: take.id)).events.map(\.kind)
            let pauses: [InputEvent.Kind] = [.paused(reason: "user"), .resumed]
            #expect(kinds.filter { pauses.contains($0) } == pauses)
        }
    }

    @Test func markersAreWrittenOnlyWhileRecording() async throws {
        try await withRig { rig in
            rig.controller.addMarker()  // no take
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            rig.controller.addMarker()
            rig.controller.togglePause()
            rig.controller.addMarker()  // paused: nothing is written
            rig.controller.togglePause()
            rig.controller.addMarker()
            let package = try #require(rig.takes.packages.first)
            let events = package.eventsURL(take: "take-001")
            #expect(await eventually {
                (try? EventLogReader.read(events).events.filter { $0.kind == .marker }.count) == 2
            })
            await rig.controller.stop(openingEditor: false)

            let watched: [InputEvent.Kind] = [.marker, .paused(reason: "user"), .resumed]
            let kinds = try EventLogReader.read(events).events.map(\.kind).filter { watched.contains($0) }
            #expect(kinds == [.marker, .paused(reason: "user"), .resumed, .marker])
        }
    }

    @Test func restartMovesTheClosedTakeToTrashAndStartsANewProject() async throws {
        try await withRig { rig in
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            let first = try #require(rig.takes.packages.first)
            try await Task.sleep(for: .seconds(1))
            rig.controller.restartTake()
            #expect(await eventually { rig.takes.packages.count == 2 && rig.controller.phase.isRecordingATake })

            let trash = ProjectTrash.folder(in: rig.folder)
            #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path) == [first.url.lastPathComponent])
            let trashed = try rig.takesOnDisk(trash.appendingPathComponent(first.url.lastPathComponent, isDirectory: true))
            #expect(trashed.count == 1 && trashed.first?.status == .complete)
            let second = try #require(rig.takes.packages.last)
            #expect(try rig.packagesOnDisk().map(\.lastPathComponent) == [second.url.lastPathComponent])
            #expect(try rig.takesOnDisk(second.url).map(\.status) == [.recording])
            let request = TakeRequest(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(rig.takes.requests == [request, request])
            #expect(rig.editorOpenings.isEmpty)
            #expect(rig.controller.lastProjectURL == nil)  // never the trash
            #expect(rig.controller.notices.isEmpty)
            #expect(rig.recordingStateChanges == 1)  // recording all along: never idle in between

            await rig.controller.stop(openingEditor: true)
            #expect(rig.editorOpenings.map(\.package.lastPathComponent) == [second.url.lastPathComponent])
            #expect(rig.controller.lastProjectURL?.lastPathComponent == second.url.lastPathComponent)
            #expect(rig.termination.began == 2 && rig.termination.ended == 2)
            #expect(rig.startFailures.isEmpty)
        }
    }

    @Test func restartRacingDiskAutoStopKeepsTheTake() async throws {
        try await withRig { rig in
            // The controller hears of the automatic close only after the restart has closed the take: the
            // restart, not the auto-stop's own stop, decides what happens to it.
            rig.autoStopGate.close()
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            rig.disk.set(importantUsage: 9_000_000_000, available: 500_000_000)
            // The disk has won: the take is closing on its own when the user restarts it.
            #expect(await eventually { rig.controller.notices.contains(.stoppedForDiskSpace) })
            rig.controller.restartTake()
            #expect(await eventually { rig.controller.phase == .idle })
            rig.autoStopGate.open()
            let recording = try #require(rig.takes.recordings.first)
            #expect(await eventually { recording.autoStops == 1 })
            try await Task.sleep(for: .milliseconds(100))  // a stop the automatic one asked for would have run

            let package = try #require(rig.takes.packages.first)
            #expect(rig.takes.packages.count == 1)  // no new take
            #expect(try rig.packagesOnDisk().map(\.lastPathComponent) == [package.url.lastPathComponent])
            #expect(!FileManager.default.fileExists(atPath: ProjectTrash.folder(in: rig.folder).path))
            #expect(rig.editorOpenings.map(\.package.lastPathComponent) == [package.url.lastPathComponent])
            #expect(rig.controller.lastProjectURL?.lastPathComponent == package.url.lastPathComponent)
            let take = try #require(try rig.takesOnDisk(package.url).first)
            #expect(take.status == .complete)
            let reasons = take.tracks.flatMap { $0.segments.map(\.endReason) }
            #expect(!reasons.isEmpty && reasons.allSatisfy { $0 == .diskFull })
            #expect(rig.termination.began == 1 && rig.termination.ended == 1)
        }
    }

    @Test func restartKeepsTheTakeWhenTheTrashFails() async throws {
        try await withRig { rig in
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            let first = try #require(rig.takes.packages.first)
            // A file where the trash folder goes: it cannot be created.
            try Data().write(to: ProjectTrash.folder(in: rig.folder))
            try await Task.sleep(for: .milliseconds(500))
            rig.controller.restartTake()
            #expect(await eventually { rig.takes.packages.count == 2 && rig.controller.phase.isRecordingATake })

            #expect(rig.controller.notices == [.couldNotMoveToTrash])
            let second = try #require(rig.takes.packages.last)
            let onDisk = try rig.packagesOnDisk().map(\.lastPathComponent).sorted()
            #expect(onDisk == [first.url.lastPathComponent, second.url.lastPathComponent].sorted())
            #expect(try rig.takesOnDisk(first.url).map(\.status) == [.complete])
            #expect(rig.controller.lastProjectURL?.lastPathComponent == first.url.lastPathComponent)
            #expect(rig.editorOpenings.isEmpty)
            await rig.controller.stop(openingEditor: false)
            #expect(rig.termination.began == 2 && rig.termination.ended == 2)
        }
    }

    @Test func restartAfterAFailedCloseKeepsTheTakeAndStartsANewOne() async throws {
        try await withRig { rig in
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            let first = try #require(rig.takes.packages.first)
            try await Task.sleep(for: .milliseconds(500))
            // The manifest is replaced through a temporary file in the package folder: closing cannot mark
            // the take complete.
            let folder = first.url.path
            try #require(chmod(folder, 0o555) == 0)
            defer { chmod(folder, 0o755) }
            rig.controller.restartTake()
            #expect(await eventually { rig.takes.packages.count == 2 && rig.controller.phase.isRecordingATake })
            try #require(chmod(folder, 0o755) == 0)

            #expect(rig.controller.notices == [.closedWithError])
            #expect(rig.controller.lastCloseError != nil)
            #expect(!FileManager.default.fileExists(atPath: ProjectTrash.folder(in: rig.folder).path))
            #expect(try rig.packagesOnDisk().count == 2)
            #expect(rig.controller.lastProjectURL?.lastPathComponent == first.url.lastPathComponent)
            await rig.controller.stop(openingEditor: false)
            #expect(rig.termination.began == 2 && rig.termination.ended == 2)
        }
    }

    @Test func aTakeLetGoIsFreed() async throws {
        try await withRig(keepingTakes: false) { rig in
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            try await Task.sleep(for: .milliseconds(300))
            rig.controller.restartTake()
            #expect(await eventually { rig.takes.made.count == 2 && rig.controller.phase.isRecordingATake })
            await rig.controller.stop(openingEditor: false)

            // Nothing holds a take, its coordinator or what that holds once the controller lets it go.
            #expect(await eventually { rig.takes.made.allSatisfy(\.isFreed) })
        }
    }

    /// A stop (quitting asks for no editor) while a restart closes the take, alone or with the disk's own
    /// stop, which then calls back late.
    @Test(arguments: [false, true], [false, true])
    func stopDuringARestartKeepsTheTake(openingEditor: Bool, diskFull: Bool) async throws {
        try await withRig { rig in
            rig.autoStopGate.close()
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            try await Task.sleep(for: .milliseconds(300))
            if diskFull {
                rig.disk.set(importantUsage: 9_000_000_000, available: 500_000_000)
                #expect(await eventually { rig.controller.notices.contains(.stoppedForDiskSpace) })
            }
            rig.stopGate.close()
            rig.controller.restartTake()
            #expect(await eventually { rig.stopGate.arrivals == 1 })  // the restart is closing the take
            let stopping = Task { await rig.controller.stop(openingEditor: openingEditor) }
            await settle()
            rig.stopGate.open()
            await stopping.value

            #expect(rig.controller.phase == .idle)
            let package = try #require(rig.takes.packages.first)
            #expect(rig.takes.packages.count == 1)  // no new take
            #expect(try rig.packagesOnDisk().map(\.lastPathComponent) == [package.url.lastPathComponent])
            #expect(!FileManager.default.fileExists(atPath: ProjectTrash.folder(in: rig.folder).path))
            let take = try #require(try rig.takesOnDisk(package.url).first)
            #expect(take.status == .complete)
            let reasons = take.tracks.flatMap { $0.segments.map(\.endReason) }
            #expect(!reasons.isEmpty && reasons.allSatisfy { $0 == (diskFull ? .diskFull : .stopped) })
            if diskFull {
                rig.autoStopGate.open()
                let recording = try #require(rig.takes.recordings.first)
                #expect(await eventually { recording.autoStops == 1 })
                try await Task.sleep(for: .milliseconds(100))  // a stop the late handler asked for would have run
            }
            #expect(rig.editorOpenings.map(\.package.lastPathComponent) == (openingEditor ? [package.url.lastPathComponent] : []))
            #expect(rig.controller.lastProjectURL?.lastPathComponent == package.url.lastPathComponent)
            #expect(rig.termination.began == 1 && rig.termination.ended == 1)
        }
    }

    @Test func quitWinsOverTheDiskStopDuringARestart() async throws {
        try await withRig { rig in
            rig.autoStopGate.close()
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            try await Task.sleep(for: .milliseconds(300))
            rig.disk.set(importantUsage: 9_000_000_000, available: 500_000_000)
            #expect(await eventually { rig.controller.notices.contains(.stoppedForDiskSpace) })
            rig.stopGate.close()
            rig.controller.restartTake()
            #expect(await eventually { rig.stopGate.arrivals == 1 })  // the restart is closing the take
            // The disk's own stop asks for the editor; then the app quits, asking for none.
            rig.autoStopGate.open()
            let recording = try #require(rig.takes.recordings.first)
            #expect(await eventually { recording.autoStops == 1 })
            await settle()
            let quitting = Task { await rig.controller.stop(openingEditor: false) }
            await settle()
            rig.stopGate.open()
            await quitting.value

            #expect(rig.controller.phase == .idle)
            #expect(rig.editorOpenings.isEmpty)
            let package = try #require(rig.takes.packages.first)
            #expect(rig.takes.packages.count == 1)
            #expect(try rig.packagesOnDisk().map(\.lastPathComponent) == [package.url.lastPathComponent])
            #expect(!FileManager.default.fileExists(atPath: ProjectTrash.folder(in: rig.folder).path))
        }
    }

    /// No segment is open when the disk stops a paused take, so none ends as `diskFull`: the take's
    /// `stoppedForDiskSpace` is what tells the restart.
    @Test func restartOfAPausedTakeTheDiskStoppedKeepsIt() async throws {
        try await withRig { rig in
            rig.autoStopGate.close()  // the restart decides, not the auto-stop's own stop
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            try await Task.sleep(for: .milliseconds(300))
            rig.controller.togglePause()
            let package = try #require(rig.takes.packages.first)
            #expect(await eventually {
                (try? rig.takesOnDisk(package.url).first?.tracks.allSatisfy { $0.segments.last?.endReason == .paused }) == true
            })
            rig.disk.set(importantUsage: 9_000_000_000, available: 500_000_000)
            #expect(await eventually { rig.controller.notices.contains(.stoppedForDiskSpace) })
            rig.controller.restartTake()
            #expect(await eventually { rig.controller.phase == .idle })
            rig.autoStopGate.open()
            let recording = try #require(rig.takes.recordings.first)
            #expect(await eventually { recording.autoStops == 1 })
            try await Task.sleep(for: .milliseconds(100))  // a stop the late handler asked for would have run

            #expect(rig.takes.packages.count == 1)  // no new take
            #expect(try rig.packagesOnDisk().map(\.lastPathComponent) == [package.url.lastPathComponent])
            #expect(!FileManager.default.fileExists(atPath: ProjectTrash.folder(in: rig.folder).path))
            let take = try #require(try rig.takesOnDisk(package.url).first)
            #expect(take.status == .complete)
            let reasons = take.tracks.flatMap { $0.segments.map(\.endReason) }
            #expect(!reasons.isEmpty && reasons.allSatisfy { $0 == .paused })
            #expect(rig.editorOpenings.map(\.package.lastPathComponent) == [package.url.lastPathComponent])
            #expect(rig.termination.began == 1 && rig.termination.ended == 1)
        }
    }

    @Test func quitWhileStartingWaitsAndLeavesNoEmptyPackage() async throws {
        try await withRig { rig in
            rig.creation.close()
            var selection = CaptureSelection.mainDisplay(1)
            selection.camera = .systemDefault
            rig.controller.startRecording(selection: selection, settings: QuickSettings())
            #expect(await eventually { rig.creation.arrivals == 1 })
            let returned = Flag()
            let quitting = Task {
                await rig.controller.stop(openingEditor: false)
                returned.set()
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(!returned.isSet)  // the start is still creating the project
            rig.creation.open()
            await quitting.value

            #expect(rig.controller.phase == .idle)
            #expect(rig.controller.notices.isEmpty)  // the camera notice was about a take that was not recorded
            #expect(try FileManager.default.contentsOfDirectory(atPath: rig.folder.path).isEmpty)
            #expect(rig.takes.packages.isEmpty)
            #expect(rig.editorOpenings.isEmpty)
            #expect(rig.termination.began == 0 && rig.termination.ended == 0)
        }
    }

    @Test func lateNoticesAfterReleaseAreIgnored() async throws {
        try await withRig { rig in
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            let first = try #require(rig.takes.recordings.first)
            first.deliverAfterClose(.paused(reason: "screenLocked"))
            await rig.controller.stop(openingEditor: false)
            await first.forwarded.value  // the late warning has been delivered
            await settle()
            #expect(!rig.controller.isPaused)

            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            #expect(!rig.controller.isPaused)
            #expect(rig.controller.notices.isEmpty)
            await rig.controller.stop(openingEditor: false)
            #expect(rig.controller.phase == .idle)
        }
    }

    // MARK: - Countdown

    @Test func countdownTicksThreeTwoOneThenStarts() async throws {
        try await withRig(countdown: 3) { rig in
            rig.sleep.hold(from: 1)
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            // In the act, before anything waits.
            #expect(rig.controller.phase == .countingDown(remaining: 3))
            #expect(rig.controller.currentRequest == TakeRequest(selection: .mainDisplay(1), settings: QuickSettings()))
            #expect(rig.recordingStateChanges == 1)  // counting down is recording, for the Dock and the updater
            for (wait, remaining) in [(1, 3), (2, 2), (3, 1)] {
                #expect(await eventually { rig.sleep.heldCall == wait })
                #expect(rig.controller.phase == .countingDown(remaining: remaining))
                if wait == 3 { rig.creation.close() }  // the project is created only once the countdown is over
                #expect(rig.creation.arrivals == 0)
                rig.sleep.release()
            }
            #expect(await eventually { rig.creation.arrivals == 1 })
            #expect(rig.controller.phase == .starting)
            rig.creation.open()
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            #expect(rig.sleep.calls == [.seconds(1), .seconds(1), .seconds(1)])
            await rig.controller.stop(openingEditor: false)
            #expect(rig.controller.currentRequest == nil)
            #expect(rig.startFailures.isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1))) func stopDuringCountdownStartsNothing() async throws {
        try await withRig(countdown: 3) { rig in
            rig.sleep.hold(from: 2)
            var selection = CaptureSelection.mainDisplay(1)
            selection.camera = .systemDefault
            rig.controller.startRecording(selection: selection, settings: QuickSettings())
            #expect(await eventually { rig.sleep.heldCall == 2 })
            #expect(rig.controller.phase == .countingDown(remaining: 2))
            // Returns although the second in progress is never let go.
            await rig.controller.stop(openingEditor: true)

            #expect(rig.sleep.wasCancelled)
            #expect(rig.controller.phase == .idle)
            #expect(rig.controller.currentRequest == nil)
            let packages = try rig.packagesOnDisk()
            #expect(packages.isEmpty)
            #expect(rig.creation.arrivals == 0 && rig.takes.requests.isEmpty)
            #expect(rig.controller.notices.isEmpty)  // nothing was recorded, so nothing is said about it
            #expect(rig.termination.began == 0 && rig.termination.ended == 0)
            #expect(rig.editorOpenings.isEmpty && rig.startFailures.isEmpty)
            #expect(rig.recordingStateChanges == 2)
        }
    }

    @Test func askingForTheMicrophoneIsVisible() async throws {
        try await withRig(microphone: .notDetermined, countdown: 3) { rig in
            rig.probe.gate.close()
            rig.sleep.hold(from: 1)
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(rig.controller.phase == .countingDown(remaining: 3))
            #expect(await eventually { rig.controller.isAskingPermission })
            #expect(rig.controller.phase == .countingDown(remaining: 3))
            #expect(rig.sleep.calls.isEmpty)  // the countdown waits for the answer
            rig.probe.gate.open()
            // Answered: no longer asking, before the countdown goes on.
            #expect(await eventually { rig.sleep.heldCall == 1 })
            #expect(!rig.controller.isAskingPermission)
            #expect(rig.controller.phase == .countingDown(remaining: 3))
            rig.sleep.releaseAll()
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            #expect(!rig.controller.isAskingPermission)
            #expect(rig.probe.requests == [.microphone])
            #expect(rig.takes.grants == [[.screenRecording, .microphone]])
            await rig.controller.stop(openingEditor: false)
        }
    }

    @Test func zeroCountdownStartsImmediately() async throws {
        try await withRig(countdown: 0) { rig in
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(rig.controller.phase == .starting)
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            #expect(rig.sleep.calls.isEmpty)
            await rig.controller.stop(openingEditor: false)
        }
    }

    @Test func noScreenPermissionOpensThePermissionsWithoutCounting() async throws {
        try await withRig(screenRecording: .denied, countdown: 3) { rig in
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(rig.controller.phase == .idle && rig.controller.currentRequest == nil)
            #expect(rig.onboardingOpenings == 1)
            #expect(rig.recordingStateChanges == 0)
            #expect(rig.sleep.calls.isEmpty && rig.probe.requests.isEmpty)
        }
    }

    @Test func restartTakeCountsDownAgain() async throws {
        try await withRig(countdown: 3) { rig in
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            #expect(rig.sleep.calls.count == 3)
            let request = TakeRequest(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(rig.controller.currentRequest == request)
            try await Task.sleep(for: .milliseconds(300))

            rig.sleep.hold(from: 4)
            rig.controller.restartTake()
            #expect(await eventually { rig.sleep.heldCall == 4 })
            #expect(rig.controller.phase == .countingDown(remaining: 3))
            #expect(rig.controller.currentRequest == request)
            #expect(rig.takes.packages.count == 1)  // the new take waits for the countdown
            rig.sleep.releaseAll()
            #expect(await eventually { rig.takes.packages.count == 2 && rig.controller.phase.isRecordingATake })
            #expect(rig.sleep.calls == Array(repeating: .seconds(1), count: 6))
            #expect(rig.controller.currentRequest == request)
            #expect(rig.recordingStateChanges == 1)
            await rig.controller.stop(openingEditor: false)
            #expect(rig.controller.currentRequest == nil)
        }
    }

    @Test func screenPermissionLostDuringTheCountdownStartsNothing() async throws {
        try await withRig(countdown: 3) { rig in
            rig.sleep.hold(from: 2)
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.sleep.heldCall == 2 })
            #expect(rig.onboardingOpenings == 0)
            rig.probe.setScreenRecording(.denied)
            rig.sleep.releaseAll()

            #expect(await eventually { rig.controller.phase == .idle })
            #expect(rig.onboardingOpenings == 1)  // as a start without the permission: the permissions open
            #expect(rig.controller.currentRequest == nil)
            let packages = try rig.packagesOnDisk()
            #expect(packages.isEmpty && rig.creation.arrivals == 0 && rig.takes.requests.isEmpty)
            #expect(rig.termination.began == 0 && rig.startFailures.isEmpty)
            #expect(rig.recordingStateChanges == 2)
        }
    }

    // MARK: - Microphone level
    // MARK: - Microphone level

    @Test func microphoneSilentNoticeComesAndGoes() async throws {
        try await withRig { rig in
            let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
            rig.now.set(start)
            #expect(rig.controller.microphoneLevel == -160)  // no take
            // A microphone that hears nothing from its first block on.
            rig.startGate.close()
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.startGate.arrivals == 1 })
            let microphone = try #require(rig.takes.factory.microphones.last)
            microphone.amplitude = 0
            rig.startGate.open()
            #expect(await eventually { rig.controller.phase == .recording(since: start) })
            #expect(await eventually { rig.controller.microphoneLevel == -160 })

            rig.now.set(start + 4)
            try await Task.sleep(for: .milliseconds(600))  // two checks of the silence
            #expect(!rig.controller.notices.contains(.microphoneSilent))
            rig.now.set(start + 5)
            #expect(await eventually { rig.controller.notices.contains(.microphoneSilent) })
            #expect(rig.controller.notices.filter { $0 == .microphoneSilent }.count == 1)

            microphone.amplitude = 0.25
            #expect(await eventually { abs(rig.controller.microphoneLevel - -12.04) < 0.1 })
            #expect(await eventually { !rig.controller.notices.contains(.microphoneSilent) })
            await rig.controller.stop(openingEditor: false)
            #expect(rig.controller.microphoneLevel == -160)
        }
    }

    @Test func aMicrophoneThatHearsIsNeverSilent() async throws {
        try await withRig { rig in
            let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
            rig.now.set(start)
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase == .recording(since: start) })
            #expect(await eventually { abs(rig.controller.microphoneLevel - -12.04) < 0.1 })
            try await Task.sleep(for: .milliseconds(300))
            rig.now.set(start + 10)
            try await Task.sleep(for: .milliseconds(600))
            #expect(!rig.controller.notices.contains(.microphoneSilent))
            await rig.controller.stop(openingEditor: false)
        }
    }

    @Test func recordsMicrophoneFollowsTheTakeNotItsNotices() async throws {
        try await withRig { rig in
            #expect(!rig.controller.recordsMicrophone)
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            #expect(rig.controller.recordsMicrophone)
            let recording = try #require(rig.takes.recordings.first)
            // The microphone is lost: from then on the take has none, however many notices come after.
            recording.inject(.trackLost(track: "mic"))
            #expect(await eventually { !rig.controller.recordsMicrophone })
            for index in 0..<8 {
                recording.inject(index.isMultiple(of: 2) ? .samplesDropped(track: "display-1") : .manifestWriteFailed)
            }
            #expect(await eventually { rig.controller.notices.count == 6 && !rig.controller.notices.contains(.trackLost(.microphone)) })
            #expect(!rig.controller.recordsMicrophone)
            await rig.controller.stop(openingEditor: false)
            #expect(!rig.controller.recordsMicrophone)

            // A take without a microphone.
            var selection = CaptureSelection.mainDisplay(1)
            selection.microphone = .off
            rig.controller.startRecording(selection: selection, settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            #expect(!rig.controller.recordsMicrophone)
            await rig.controller.stop(openingEditor: false)
        }
    }

    @Test func refusedPauseLeavesTheTakeUnpaused() async throws {
        try await withRig { rig in
            // The take closes on its own (the disk is full), and the controller hears of it late: a pause
            // asked for meanwhile is refused.
            rig.autoStopGate.close()
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            rig.disk.set(importantUsage: 9_000_000_000, available: 500_000_000)
            #expect(await eventually { rig.controller.notices.contains(.stoppedForDiskSpace) })
            rig.controller.togglePause()
            #expect(rig.controller.isUserPaused)  // at once, while the take is asked
            #expect(await eventually { !rig.controller.isUserPaused })
            #expect(rig.controller.phase.isRecordingATake)
            rig.autoStopGate.open()
            #expect(await eventually { rig.controller.phase == .idle })
        }
    }

    // MARK: - After a stop

    @Test func stayHereNeverOpensTheEditor() async throws {
        try await withRig(afterStop: .stayHere) { rig in
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            rig.controller.addMarker()
            #expect(await eventually { rig.confirmations == [.markerAdded] })
            #expect(rig.controller.lastSaved == nil)
            rig.controller.stopRecording()
            #expect(await eventually { rig.controller.phase == .idle && rig.controller.lastSaved != nil })
            try await Task.sleep(for: .milliseconds(100))  // an editor asked for would have opened

            #expect(rig.editorOpenings.isEmpty)
            let saved = try #require(rig.controller.lastSaved)
            let package = try #require(rig.takes.packages.first)
            #expect(saved.projectURL == package.url && rig.controller.lastProjectURL == package.url)
            #expect(saved.markers == 1)
            #expect(saved.trackKinds == [.display, .microphone])
            #expect(!saved.openedEditor)
        }
    }

    @Test(arguments: AfterStop.allCases) func diskAutoStopFollowsTheAfterStopSetting(afterStop: AfterStop) async throws {
        try await withRig(afterStop: afterStop) { rig in
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            rig.disk.set(importantUsage: 9_000_000_000, available: 500_000_000)
            #expect(await eventually { rig.controller.phase == .idle && rig.controller.lastSaved != nil })
            let recording = try #require(rig.takes.recordings.first)
            #expect(await eventually { recording.autoStops == 1 })
            try await Task.sleep(for: .milliseconds(100))  // the stop the automatic one asks for has run too

            let saved = try #require(rig.controller.lastSaved)
            #expect(saved.openedEditor == (afterStop == .openEditor))
            #expect(rig.editorOpenings.count == (afterStop == .openEditor ? 1 : 0))
            #expect(rig.controller.notices.contains(.stoppedForDiskSpace))
            #expect(saved.projectURL == rig.takes.packages.first?.url)
        }
    }

    @Test func resumedStreamClearsTheWarning() async throws {
        try await withRig { rig in
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            let microphone = try #require(rig.takes.factory.microphones.last)
            microphone.failNow(domain: "AVFoundationErrorDomain", code: -11819)
            #expect(await eventually { rig.controller.notices.contains(.streamInterrupted(.microphone)) })
            // It comes back after the first restart's wait.
            #expect(await eventually { rig.controller.notices.contains(.streamResumed(.microphone)) })
            #expect(!rig.controller.notices.contains(.streamInterrupted(.microphone)))

            // Interrupted again: that it came back no longer holds, until it comes back again.
            microphone.failNow(domain: "AVFoundationErrorDomain", code: -11819)
            #expect(await eventually { rig.controller.notices == [.streamInterrupted(.microphone)] })
            #expect(await eventually { rig.controller.notices == [.streamResumed(.microphone)] })
            await rig.controller.stop(openingEditor: false)
        }
    }

    @Test func savedTakeKeepsTheRecordedTime() async throws {
        try await withRig { rig in
            let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
            rig.now.set(start)
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase == .recording(since: start) })
            rig.now.set(start + 3)
            rig.controller.stopRecording()
            #expect(await eventually { rig.controller.lastSaved != nil })

            let saved = try #require(rig.controller.lastSaved)
            #expect(saved.duration == .seconds(3))
            #expect(saved.markers == 0 && saved.openedEditor)
            #expect(rig.editorOpenings.map(\.package) == [saved.projectURL])
        }
    }

    @Test func aTakeThatClosedWithAnErrorIsStillSaved() async throws {
        try await withRig(afterStop: .stayHere) { rig in
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            let package = try #require(rig.takes.packages.first)
            try await Task.sleep(for: .milliseconds(500))
            // The manifest is replaced through a temporary file in the package folder: closing cannot mark the
            // take complete, and says nothing about its tracks.
            let folder = package.url.path
            try #require(chmod(folder, 0o555) == 0)
            defer { chmod(folder, 0o755) }
            rig.controller.stopRecording()
            #expect(await eventually { rig.controller.phase == .idle && rig.controller.lastSaved != nil })
            try #require(chmod(folder, 0o755) == 0)

            #expect(rig.controller.notices.contains(.closedWithError) && rig.controller.lastCloseError != nil)
            let saved = try #require(rig.controller.lastSaved)
            #expect(saved.projectURL == package.url)
            #expect(saved.trackKinds == [.display, .microphone])  // the take's sources
            #expect(!saved.openedEditor && rig.editorOpenings.isEmpty)
        }
    }

    @Test func quittingShowsNoSavedTake() async throws {
        try await withRig { rig in
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            await rig.controller.stop(openingEditor: false)
            #expect(rig.controller.phase == .idle)
            #expect(rig.controller.lastSaved == nil && rig.controller.lastProjectURL != nil)
            #expect(rig.editorOpenings.isEmpty)
        }
    }

    @Test func confirmationsAreReported() async throws {
        try await withRig(countdown: 3) { rig in
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            #expect(rig.confirmations.isEmpty)
            rig.controller.addMarker()
            #expect(await eventually { rig.confirmations == [.markerAdded] })
            rig.controller.togglePause()
            #expect(await eventually { rig.confirmations == [.markerAdded, .paused] })
            rig.controller.togglePause()  // resuming says nothing
            try await Task.sleep(for: .milliseconds(300))

            // The restart's countdown: its first second is over, the second one is held.
            rig.sleep.hold(from: 5)
            rig.controller.restartTake()
            #expect(await eventually { rig.sleep.heldCall == 5 })
            #expect(rig.controller.phase == .countingDown(remaining: 2))
            #expect(rig.confirmations == [.markerAdded, .paused, .movedToTrash])
            await rig.controller.stop(openingEditor: true)

            #expect(rig.controller.phase == .idle)
            #expect(rig.confirmations == [.markerAdded, .paused, .movedToTrash, .countdownCancelled])
            // Neither a restart nor a cancelled countdown saves a take.
            #expect(rig.controller.lastSaved == nil && rig.editorOpenings.isEmpty)
        }
    }

    @Test func aNewTakeStartsWithoutTheLastOnesNotices() async throws {
        try await withRig(hasMicrophone: false, countdown: 3) { rig in
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            #expect(rig.controller.notices == [.noMicrophone])
            await rig.controller.stop(openingEditor: false)
            #expect(rig.controller.notices == [.noMicrophone])  // about the last take, until the next one

            // The next take's countdown: what was said about the last one no longer applies, and the island
            // hears the same notice again as a new one once the take starts.
            rig.sleep.hold(from: 4)
            rig.controller.startRecording(selection: .mainDisplay(1), settings: QuickSettings())
            #expect(rig.controller.notices.isEmpty)
            #expect(await eventually { rig.sleep.heldCall == 4 })
            #expect(rig.controller.notices.isEmpty)
            rig.sleep.releaseAll()
            #expect(await eventually { rig.controller.phase.isRecordingATake })
            #expect(rig.controller.notices == [.noMicrophone])
            await rig.controller.stop(openingEditor: false)
        }
    }
}

// MARK: - Rig

extension RecordingController.Phase {
    fileprivate var isRecordingATake: Bool {
        if case .recording = self { true } else { false }
    }
}

/// Lets the main-actor jobs already queued (a stop just asked for) run up to their next wait.
@MainActor private func settle() async {
    for _ in 0..<10 { await Task.yield() }
}

/// A controller whose takes are recorded in a fresh folder with its own defaults, both removed afterwards.
/// Without `keepingTakes`, the rig holds the takes it makes only weakly (`PreparedTakes.made`).
/// The countdown lasts `countdown` seconds (none unless a test is about it), each of them a wait of
/// `Rig.sleep`, which returns at once unless the test holds it. A stop does `afterStop`.
@MainActor private func withRig(
    screenRecording: PermissionState = .granted, microphone: PermissionState = .granted, hasMicrophone: Bool = true,
    keepingTakes: Bool = true, countdown: Int = 0, afterStop: AfterStop = .openEditor, _ body: (Rig) async throws -> Void
) async throws {
    try await withTemporaryDirectory { directory in
        let suite = "RecordingControllerTests-\(UUID().uuidString)"
        let defaults = try unwrap(UserDefaults(suiteName: suite), "a defaults suite")
        defer { defaults.removePersistentDomain(forName: suite) }
        SettingsStore(defaults: defaults).settings = RecorderSettings(countdownSeconds: countdown, afterStop: afterStop)
        try await body(Rig(
            in: directory, defaults: defaults, screenRecording: screenRecording, microphone: microphone,
            hasMicrophone: hasMicrophone, keepingTakes: keepingTakes))
    }
}

/// A `RecordingController` with an environment the test holds: gates at each place a start or a stop
/// waits, a disk whose free space the test sets, and a record of what the controller asked for.
@MainActor private final class Rig {
    struct EditorOpening {
        var package: URL
        var take: String?
    }

    let folder: URL
    let probe: GatedProbe
    /// Passed by `createPackage`, which blocks while it is closed.
    let creation: Gate
    /// Passed by every take's `start()` before the coordinator's.
    let startGate: Gate
    /// Passed by every take's `stop()` before the coordinator's.
    let stopGate: Gate
    /// Passed by every take's auto-stop before the controller's handler is called.
    let autoStopGate: Gate
    let termination: CountingTerminationGuard
    let disk: FakeDisk
    let now = TestNow()
    /// The countdown's waits.
    let sleep = CountdownSleep()
    let takes: PreparedTakes
    let controller: RecordingController
    private(set) var editorOpenings: [EditorOpening] = []
    private(set) var startFailures: [any Error] = []
    /// What the controller confirmed, in order.
    private(set) var confirmations: [IslandConfirmation] = []
    /// How many times `isRecording` changed.
    private(set) var recordingStateChanges = 0
    private(set) var onboardingOpenings = 0

    init(
        in directory: URL, defaults: UserDefaults, screenRecording: PermissionState, microphone: PermissionState,
        hasMicrophone: Bool, keepingTakes: Bool
    ) {
        let folder = directory.appendingPathComponent("Movies/Toma", isDirectory: true)
        let (creation, startGate, stopGate, autoStopGate) = (Gate(), Gate(), Gate(), Gate())
        let termination = CountingTerminationGuard()
        let disk = FakeDisk()
        let takes = PreparedTakes(
            disk: disk, startGate: startGate, stopGate: stopGate, autoStopGate: autoStopGate, keepingTakes: keepingTakes)
        self.folder = folder
        probe = GatedProbe(screenRecording: screenRecording, microphone: microphone)
        (self.creation, self.startGate, self.stopGate, self.autoStopGate) = (creation, startGate, stopGate, autoStopGate)
        self.termination = termination
        self.disk = disk
        self.takes = takes
        let environment = TakeEnvironment(
            projectsFolder: folder,
            app: AppInfo(name: "Tests", version: "0"),
            projectNamePrefix: "Recording",
            hasMicrophone: { hasMicrophone },
            createPackage: { folder, prefix, app, now in
                creation.passBlocking()
                return try ProjectFolder.createPackage(in: folder, prefix: prefix, app: app, now: now)
            },
            prepareTake: { package, request, granted in try takes.prepare(package, request, granted) },
            termination: termination,
            now: { [now] in now.date },
            sleep: { [sleep] duration in try await sleep.sleep(duration) })
        controller = RecordingController(probe: probe, environment: environment, defaults: defaults)
        controller.openEditor = { [weak self] url, take in self?.editorOpenings.append(EditorOpening(package: url, take: take)) }
        controller.showStartFailure = { [weak self] error in self?.startFailures.append(error) }
        controller.onConfirmation = { [weak self] confirmation in self?.confirmations.append(confirmation) }
        controller.recordingStateChanged = { [weak self] in self?.recordingStateChanges += 1 }
        controller.openOnboarding = { [weak self] in self?.onboardingOpenings += 1 }
    }

    /// The packages in the projects folder; none if it was never created.
    func packagesOnDisk() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == ProjectPackage.fileExtension }
    }

    func takesOnDisk(_ package: URL) throws -> [TakeRecord] {
        let data = try Data(contentsOf: ProjectPackage(url: package).manifestURL)
        return try ProjectJSON.decoder().decode(Manifest.self, from: data).takes
    }
}

/// What `prepareTake` was asked for, and the takes it made: the plan `TakePlanner` makes of the request
/// with display 1 connected and `factory`'s synthetic sources, recorded by a coordinator behind the rig's gates.
@MainActor private final class PreparedTakes {
    /// A take `prepare` made, held weakly: whether it has been freed.
    struct MadeTake {
        weak var recording: GatedTakeRecording?
        weak var coordinator: RecordingCoordinator?

        var isFreed: Bool { recording == nil && coordinator == nil }
    }

    private static let displays = [
        DisplayInfo(id: 1, frame: Rect(x: 0, y: 0, width: 64, height: 36), scale: 1, isMain: true, maximumFramesPerSecond: 60),
    ]

    let factory = FakeFactory()
    private(set) var requests: [TakeRequest] = []
    /// The permissions granted for each request.
    private(set) var grants: [Set<PermissionKind>] = []
    /// The packages of the takes made.
    private(set) var packages: [ProjectPackage] = []
    /// The takes made, unless they are not kept.
    private(set) var recordings: [GatedTakeRecording] = []
    /// Every take made.
    private(set) var made: [MadeTake] = []
    private let disk: FakeDisk
    private let startGate: Gate
    private let stopGate: Gate
    private let autoStopGate: Gate
    private let keepingTakes: Bool

    init(disk: FakeDisk, startGate: Gate, stopGate: Gate, autoStopGate: Gate, keepingTakes: Bool) {
        self.disk = disk
        self.startGate = startGate
        self.stopGate = stopGate
        self.autoStopGate = autoStopGate
        self.keepingTakes = keepingTakes
    }

    func prepare(_ package: ProjectPackage, _ request: TakeRequest, _ granted: Set<PermissionKind>) throws -> PreparedTake {
        requests.append(request)
        grants.append(granted)
        let plan = try TakePlanner.plan(
            request.selection, settings: request.settings, displays: Self.displays, granted: granted, factory: factory)
        packages.append(package)
        let coordinator = RecordingCoordinator(
            package: package, sources: plan.sources, input: plan.input,
            diskMonitor: disk.monitor(volume: package.url), systemActivity: AsyncStream { $0.finish() })
        let recording = GatedTakeRecording(
            coordinator: coordinator, startGate: startGate, stopGate: stopGate, autoStopGate: autoStopGate)
        if keepingTakes { recordings.append(recording) }
        made.append(MadeTake(recording: recording, coordinator: coordinator))
        return PreparedTake(
            recording: recording, microphone: plan.optional.first,
            kinds: Dictionary(uniqueKeysWithValues: plan.sources.map { ($0.trackID, $0.kind) }),
            microphoneMeter: plan.microphoneMeter)
    }
}

/// A coordinator whose `start()` and `stop()` first pass a gate the test holds, and whose auto-stop
/// handler is called once a third one lets it through. Its warnings are the coordinator's, then the ones
/// `deliverAfterClose` queued, a little after the coordinator's have ended.
private final class GatedTakeRecording: TakeRecording {
    let coordinator: RecordingCoordinator
    let warnings: AsyncStream<RecordingWarning>
    /// Ends once `warnings` has finished.
    let forwarded: Task<Void, Never>
    private let startGate: Gate
    private let stopGate: Gate
    private let autoStopGate: Gate
    private let afterClose: WarningLog
    /// Where `warnings` comes from.
    private let continuation: AsyncStream<RecordingWarning>.Continuation
    private let autoStopCount = Atomic(0)

    /// How many times the auto-stop handler has been called.
    var autoStops: Int { autoStopCount.load(ordering: .relaxed) }

    init(coordinator: RecordingCoordinator, startGate: Gate, stopGate: Gate, autoStopGate: Gate) {
        self.coordinator = coordinator
        self.startGate = startGate
        self.stopGate = stopGate
        self.autoStopGate = autoStopGate
        let afterClose = WarningLog()
        self.afterClose = afterClose
        let (stream, continuation) = AsyncStream.makeStream(of: RecordingWarning.self)
        warnings = stream
        self.continuation = continuation
        forwarded = Task {
            for await warning in coordinator.warnings { continuation.yield(warning) }
            let late = afterClose.all
            if !late.isEmpty {
                // After the controller would have let go of the take, had it not waited for these.
                try? await Task.sleep(for: .milliseconds(50))
                for warning in late { continuation.yield(warning) }
            }
            continuation.finish()
        }
    }

    /// `warning` comes once the coordinator's warnings have ended, as the take's last.
    func deliverAfterClose(_ warning: RecordingWarning) {
        afterClose.append(warning)
    }

    /// `warning` comes now, among the coordinator's.
    func inject(_ warning: RecordingWarning) {
        continuation.yield(warning)
    }

    func setOnAutoStop(_ handler: @escaping @Sendable (TakeRecord, (any Error)?) -> Void) async {
        let gate = autoStopGate
        await coordinator.setOnAutoStop { [weak self] record, error in
            Task {
                await gate.pass()
                handler(record, error)
                self?.autoStopCount.add(1, ordering: .relaxed)
            }
        }
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
}

/// Holds whoever passes it while it is closed, and counts who came.
private final class Gate: Sendable {
    private struct State {
        var isOpen = true
        var arrivals = 0
        var waiting: [CheckedContinuation<Void, Never>] = []
        var blocked: [DispatchSemaphore] = []
    }

    private let state = Mutex(State())

    var arrivals: Int { state.withLock { $0.arrivals } }

    func close() {
        state.withLock { $0.isOpen = false }
    }

    func open() {
        let (waiting, blocked) = state.withLock { state in
            state.isOpen = true
            defer { (state.waiting, state.blocked) = ([], []) }
            return (state.waiting, state.blocked)
        }
        for continuation in waiting { continuation.resume() }
        for semaphore in blocked { semaphore.signal() }
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

    /// For a synchronous caller: blocks its thread while the gate is closed.
    func passBlocking() {
        let semaphore = DispatchSemaphore(value: 0)
        let isOpen = state.withLock { state in
            state.arrivals += 1
            if !state.isOpen { state.blocked.append(semaphore) }
            return state.isOpen
        }
        if !isOpen { semaphore.wait() }
    }
}

/// Screen recording and the microphone start as given, and the system prompt for the microphone, held
/// by `gate`, grants it.
private final class GatedProbe: PermissionProbe {
    let gate = Gate()
    private let screenRecording: Mutex<PermissionState>
    private let microphone: Mutex<PermissionState>
    private let requested = Mutex<[PermissionKind]>([])

    /// What was requested, in order.
    var requests: [PermissionKind] { requested.withLock { $0 } }

    init(screenRecording: PermissionState, microphone: PermissionState) {
        self.screenRecording = Mutex(screenRecording)
        self.microphone = Mutex(microphone)
    }

    /// The user changes screen recording in System Settings.
    func setScreenRecording(_ state: PermissionState) {
        screenRecording.withLock { $0 = state }
    }

    func state(of kind: PermissionKind) -> PermissionState {
        switch kind {
        case .screenRecording: screenRecording.withLock { $0 }
        case .microphone: microphone.withLock { $0 }
        }
    }

    func request(_ kind: PermissionKind) async -> PermissionState {
        requested.withLock { $0.append(kind) }
        await gate.pass()
        guard kind == .microphone else { return state(of: kind) }
        microphone.withLock { $0 = .granted }
        return .granted
    }
}

/// The countdown's `sleep`: records every wait and returns at once, except the waits from the one
/// `hold(from:)` names on, each held until `release()`. A held wait whose task is cancelled throws
/// `CancellationError` at once, as `Task.sleep` does.
private final class CountdownSleep: Sendable {
    private struct State {
        var calls: [Duration] = []
        /// The first call (1-based) that is held.
        var holdingFrom: Int?
        /// The call held now, and who waits in it.
        var held: (call: Int, continuation: CheckedContinuation<Void, any Error>)?
        /// The call cancelled before it was held.
        var cancelledCall: Int?
        var wasCancelled = false
    }

    private let state = Mutex(State())

    /// Every wait asked for, in order.
    var calls: [Duration] { state.withLock { $0.calls } }
    /// The wait being held, by its number (1-based).
    var heldCall: Int? { state.withLock { $0.held?.call } }
    var wasCancelled: Bool { state.withLock { $0.wasCancelled } }

    func hold(from call: Int) {
        state.withLock { $0.holdingFrom = call }
    }

    /// Lets the wait being held go on; the next ones are still held.
    func release() {
        let held = state.withLock { state in
            defer { state.held = nil }
            return state.held
        }
        held?.continuation.resume()
    }

    /// Lets the wait being held go on, and holds none from now on.
    func releaseAll() {
        state.withLock { $0.holdingFrom = nil }
        release()
    }

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        let call = state.withLock { state in
            state.calls.append(duration)
            return state.calls.count
        }
        guard let first = state.withLock({ $0.holdingFrom }), call >= first else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { state in
                    guard state.cancelledCall != call else { return true }
                    state.held = (call, continuation)
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let held = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                state.wasCancelled = true
                guard let held = state.held, held.call == call else {
                    state.cancelledCall = call
                    return nil
                }
                state.held = nil
                return held.continuation
            }
            held?.resume(throwing: CancellationError())
        }
    }
}

private final class CountingTerminationGuard: TerminationGuarding {
    private let counts = Mutex((began: 0, ended: 0))

    var began: Int { counts.withLock { $0.began } }
    var ended: Int { counts.withLock { $0.ended } }

    func takeBegan() {
        counts.withLock { $0.began += 1 }
    }

    func takeEnded() {
        counts.withLock { $0.ended += 1 }
    }
}

/// The time the controller reads: the real one, or the one the test set.
private final class TestNow: Sendable {
    private let fixed = Mutex<Date?>(nil)

    var date: Date { fixed.withLock { $0 } ?? Date() }

    func set(_ date: Date?) {
        fixed.withLock { $0 = date }
    }
}

private final class Flag: Sendable {
    private let value = Atomic(false)

    var isSet: Bool { value.load(ordering: .relaxed) }

    func set() {
        value.store(true, ordering: .relaxed)
    }
}
