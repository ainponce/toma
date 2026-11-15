// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import ProjectFormat
import Recording
import SyntheticCapture
import Testing

@Suite struct TakePlannerTests {
    private static let displays = [
        DisplayInfo(id: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982), scale: 2, isMain: true, maximumFramesPerSecond: 120),
        DisplayInfo(id: 2, frame: Rect(x: 1512, y: 0, width: 1920, height: 1080), scale: 1, isMain: false, maximumFramesPerSecond: 60),
    ]
    private static let allGranted: Set<PermissionKind> = [.screenRecording, .microphone]

    @Test func mainDisplaySelectionRecordsItWithTheSystemMicrophone() {
        #expect(CaptureSelection.mainDisplay(3) == CaptureSelection(
            mode: .display, displayIDs: [3], camera: .off, microphone: .systemDefault, systemAudio: .off))
        #expect(QuickSettings().framesPerSecond(display: 3) == 60 && QuickSettings().displayScale == .native)
    }

    @Test func frameRatesBelowOneAreRecordedAtSixty() throws {
        let settings = QuickSettings(framesPerSecondByDisplay: [1: 0, 2: -30])
        #expect(settings.framesPerSecond(display: 1) == 60 && settings.framesPerSecond(display: 2) == 60)
        #expect(QuickSettings(framesPerSecondByDisplay: [1: 24]).framesPerSecond(display: 1) == 24)

        var selection = CaptureSelection.mainDisplay(1)
        selection.displayIDs = [1, 2]
        let factory = FakeFactory()
        let plan = try TakePlanner.plan(selection, settings: settings, displays: Self.displays, granted: Self.allGranted, factory: factory)
        #expect(plan.sources.map(\.media) == [.video(framesPerSecond: 60), .video(framesPerSecond: 60), .audio])
    }

    @Test func planForTwoDisplaysMakesTwoDisplayTracksInOrder() throws {
        var selection = CaptureSelection.mainDisplay(1)
        selection.displayIDs = [2, 1]
        let settings = QuickSettings(framesPerSecondByDisplay: [2: 30], displayScale: .points)
        let factory = FakeFactory()
        let plan = try TakePlanner.plan(selection, settings: settings, displays: Self.displays, granted: Self.allGranted, factory: factory)

        #expect(TakePlanner.problem(with: selection, displays: Self.displays) == nil)
        #expect(plan.sources.map(\.trackID) == ["display-2", "display-1", "mic"])
        #expect(plan.sources.map(\.media) == [.video(framesPerSecond: 30), .video(framesPerSecond: 60), .audio])
        #expect(factory.calls == [
            .display(id: 2, framesPerSecond: 30, scale: .points),
            .display(id: 1, framesPerSecond: 60, scale: .points),
            .microphone(.systemDefault),
            .input(displayIDs: [2, 1]),
        ])
        let microphone = try #require(plan.optional.first)
        #expect(plan.optional.count == 1 && plan.sources.last === microphone)
    }

    @Test func planRecordsARepeatedDisplayOnce() throws {
        var selection = CaptureSelection.mainDisplay(1)
        selection.displayIDs = [1, 2, 1]
        let factory = FakeFactory()
        let plan = try TakePlanner.plan(selection, settings: QuickSettings(), displays: Self.displays, granted: Self.allGranted, factory: factory)
        #expect(plan.sources.map(\.trackID) == ["display-1", "display-2", "mic"])
        #expect(factory.calls.last == .input(displayIDs: [1, 2]))
    }

    @Test func planUsesTheChosenMicrophoneOnlyWhenGranted() throws {
        var selection = CaptureSelection.mainDisplay(1)
        selection.microphone = .device(uniqueID: "usb-1")
        let factory = FakeFactory()
        let plan = try TakePlanner.plan(selection, settings: QuickSettings(), displays: Self.displays, granted: Self.allGranted, factory: factory)
        #expect(factory.calls == [
            .display(id: 1, framesPerSecond: 60, scale: .native), .microphone(.device(uniqueID: "usb-1")), .input(displayIDs: [1]),
        ])
        let microphone = try #require(plan.optional.first)
        #expect(plan.optional.count == 1 && plan.sources.last === microphone)
        // Metered inside: the source the take tracks is the one it measures.
        let meter = try #require(plan.microphoneMeter)
        #expect(microphone.base === meter && meter.base === factory.microphones.first && factory.microphones.count == 1)

        var off = selection
        off.microphone = .off
        let cases: [(CaptureSelection, Set<PermissionKind>)] = [(off, Self.allGranted), (selection, [.screenRecording])]
        for (selection, granted) in cases {
            let factory = FakeFactory()
            let plan = try TakePlanner.plan(selection, settings: QuickSettings(), displays: Self.displays, granted: granted, factory: factory)
            #expect(plan.sources.map(\.trackID) == ["display-1"])
            #expect(plan.optional.isEmpty && plan.microphoneMeter == nil)
            #expect(factory.calls == [.display(id: 1, framesPerSecond: 60, scale: .native), .input(displayIDs: [1])])
        }
    }

    @Test func planRefusesWithoutAScreen() {
        var noScreen = CaptureSelection.mainDisplay(1)
        noScreen.displayIDs = []
        let cases: [(CaptureSelection, TakePlanError)] = [(noScreen, .noScreenChosen), (.mainDisplay(9), .displayNotFound(9))]
        for (selection, expected) in cases {
            let factory = FakeFactory()
            #expect(throws: expected) {
                try TakePlanner.plan(selection, settings: QuickSettings(), displays: Self.displays, granted: Self.allGranted, factory: factory)
            }
            #expect(TakePlanner.problem(with: selection, displays: Self.displays) == expected)
            #expect(factory.calls.isEmpty)
        }
    }

    @Test func planRefusesWhatThisSliceCannotRecord() throws {
        var window = CaptureSelection.mainDisplay(1)
        window.mode = .window
        window.windowID = 42
        var area = CaptureSelection.mainDisplay(1)
        area.mode = .area
        area.area = AreaChoice(displayID: 1, rect: Rect(x: 100, y: 100, width: 640, height: 360))
        var systemAudio = CaptureSelection.mainDisplay(1)
        systemAudio.systemAudio = .all
        for selection in [window, area, systemAudio] {
            let factory = FakeFactory()
            #expect(throws: TakePlanError.notAvailableYet) {
                try TakePlanner.plan(selection, settings: QuickSettings(), displays: Self.displays, granted: Self.allGranted, factory: factory)
            }
            #expect(TakePlanner.problem(with: selection, displays: Self.displays) == .notAvailableYet)
            #expect(factory.calls.isEmpty)
        }

        // The camera is not refused: the plan records without it (the controller says so).
        var camera = CaptureSelection.mainDisplay(1)
        camera.camera = .systemDefault
        let factory = FakeFactory()
        let plan = try TakePlanner.plan(camera, settings: QuickSettings(), displays: Self.displays, granted: Self.allGranted, factory: factory)
        #expect(TakePlanner.problem(with: camera, displays: Self.displays) == nil)
        #expect(plan.sources.map(\.trackID) == ["display-1", "mic"])
        #expect(factory.calls == [.display(id: 1, framesPerSecond: 60, scale: .native), .microphone(.systemDefault), .input(displayIDs: [1])])
    }
}

/// Makes synthetic sources, and records what it was asked for in order: a 64 × 36 display per display
/// ID, a microphone that fails its first `microphoneFailures` starts, and no input.
final class FakeFactory: CaptureSourceFactory {
    enum Call: Equatable {
        case display(id: UInt32, framesPerSecond: Int, scale: CaptureScale)
        case microphone(DeviceChoice)
        case input(displayIDs: [UInt32])
    }

    /// How many times each new microphone fails to start.
    var microphoneFailures = 0
    private(set) var calls: [Call] = []
    /// The microphones made, oldest first.
    private(set) var microphones: [SyntheticAudioSource] = []

    func display(id: UInt32, framesPerSecond: Int, scale: CaptureScale) -> any CaptureSource {
        calls.append(.display(id: id, framesPerSecond: framesPerSecond, scale: scale))
        return SyntheticVideoSource(trackID: "display-\(id)", width: 64, height: 36, framesPerSecond: framesPerSecond)
    }

    func microphone(_ choice: DeviceChoice) -> any CaptureSource {
        calls.append(.microphone(choice))
        let microphone = SyntheticAudioSource()
        microphone.failOnStart = microphoneFailures
        microphones.append(microphone)
        return microphone
    }

    func input(displayIDs: [UInt32]) -> any InputRecorder {
        calls.append(.input(displayIDs: displayIDs))
        return NoInputRecorder()
    }
}
