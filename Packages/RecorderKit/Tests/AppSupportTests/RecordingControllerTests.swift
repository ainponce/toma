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
            await rig.controller.stop(openingEditor: false)

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
@MainActor private func withRig(
    microphone: PermissionState = .granted, hasMicrophone: Bool = true, _ body: (Rig) async throws -> Void
) async throws {
    try await withTemporaryDirectory { directory in
        let suite = "RecordingControllerTests-\(UUID().uuidString)"
        let defaults = try unwrap(UserDefaults(suiteName: suite), "a defaults suite")
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(Rig(in: directory, defaults: defaults, microphone: microphone, hasMicrophone: hasMicrophone))
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
    let termination: CountingTerminationGuard
    let disk: FakeDisk
    let takes: PreparedTakes
    let controller: RecordingController
    private(set) var editorOpenings: [EditorOpening] = []
    private(set) var startFailures: [any Error] = []

    init(in directory: URL, defaults: UserDefaults, microphone: PermissionState, hasMicrophone: Bool) {
        let folder = directory.appendingPathComponent("Movies/Toma", isDirectory: true)
        let (creation, startGate, stopGate) = (Gate(), Gate(), Gate())
        let termination = CountingTerminationGuard()
        let disk = FakeDisk()
        let takes = PreparedTakes(disk: disk, startGate: startGate, stopGate: stopGate)
        self.folder = folder
        probe = GatedProbe(microphone: microphone)
        (self.creation, self.startGate, self.stopGate) = (creation, startGate, stopGate)
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
            now: { Date() })
        controller = RecordingController(probe: probe, environment: environment, defaults: defaults)
        controller.openEditor = { [weak self] url, take in self?.editorOpenings.append(EditorOpening(package: url, take: take)) }
        controller.showStartFailure = { [weak self] error in self?.startFailures.append(error) }
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
    private static let displays = [
        DisplayInfo(id: 1, frame: Rect(x: 0, y: 0, width: 64, height: 36), scale: 1, isMain: true, maximumFramesPerSecond: 60),
    ]

    let factory = FakeFactory()
    private(set) var requests: [TakeRequest] = []
    /// The permissions granted for each request.
    private(set) var grants: [Set<PermissionKind>] = []
    /// The packages of the takes made.
    private(set) var packages: [ProjectPackage] = []
    private(set) var recordings: [GatedTakeRecording] = []
    private let disk: FakeDisk
    private let startGate: Gate
    private let stopGate: Gate

    init(disk: FakeDisk, startGate: Gate, stopGate: Gate) {
        self.disk = disk
        self.startGate = startGate
        self.stopGate = stopGate
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
        let recording = GatedTakeRecording(coordinator: coordinator, startGate: startGate, stopGate: stopGate)
        recordings.append(recording)
        return PreparedTake(
            recording: recording, microphone: plan.optional.first,
            kinds: Dictionary(uniqueKeysWithValues: plan.sources.map { ($0.trackID, $0.kind) }))
    }
}

/// A coordinator whose `start()` and `stop()` first pass a gate the test holds. Its warnings are the
/// coordinator's, then the ones `deliverAfterClose` queued, a little after the coordinator's have ended.
private final class GatedTakeRecording: TakeRecording {
    let coordinator: RecordingCoordinator
    let warnings: AsyncStream<RecordingWarning>
    /// Ends once `warnings` has finished.
    let forwarded: Task<Void, Never>
    private let startGate: Gate
    private let stopGate: Gate
    private let afterClose: WarningLog
    private let autoStopCount = Atomic(0)

    /// How many times the coordinator has called the auto-stop handler.
    var autoStops: Int { autoStopCount.load(ordering: .relaxed) }

    init(coordinator: RecordingCoordinator, startGate: Gate, stopGate: Gate) {
        self.coordinator = coordinator
        self.startGate = startGate
        self.stopGate = stopGate
        let afterClose = WarningLog()
        self.afterClose = afterClose
        let (stream, continuation) = AsyncStream.makeStream(of: RecordingWarning.self)
        warnings = stream
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

    func setOnAutoStop(_ handler: @escaping @Sendable (TakeRecord, (any Error)?) -> Void) async {
        await coordinator.setOnAutoStop { [weak self] record, error in
            handler(record, error)
            self?.autoStopCount.add(1, ordering: .relaxed)
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

/// Screen recording is granted; the microphone starts as given, and the system prompt for it, held
/// by `gate`, grants it.
private final class GatedProbe: PermissionProbe {
    let gate = Gate()
    private let microphone: Mutex<PermissionState>
    private let requested = Mutex<[PermissionKind]>([])

    /// What was requested, in order.
    var requests: [PermissionKind] { requested.withLock { $0 } }

    init(microphone: PermissionState) {
        self.microphone = Mutex(microphone)
    }

    func state(of kind: PermissionKind) -> PermissionState {
        switch kind {
        case .screenRecording: .granted
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

private final class Flag: Sendable {
    private let value = Atomic(false)

    var isSet: Bool { value.load(ordering: .relaxed) }

    func set() {
        value.store(true, ordering: .relaxed)
    }
}
