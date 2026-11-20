// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import CoreGraphics
import ProjectFormat
import Recording
import SyntheticCapture
import Testing

@Suite struct TakePlannerTests {
    private static let displays = [
        DisplayInfo(id: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982), scale: 2, isMain: true, maximumFramesPerSecond: 120),
        DisplayInfo(id: 2, frame: Rect(x: 1512, y: 0, width: 1920, height: 1080), scale: 1, isMain: false, maximumFramesPerSecond: 60),
    ]
    private static let allGranted: Set<PermissionKind> = [.screenRecording, .microphone, .camera, .systemAudio]

    @Test func mainDisplaySelectionRecordsItWithTheSystemMicrophone() {
        #expect(CaptureSelection.mainDisplay(3) == CaptureSelection(
            mode: .display, displayIDs: [3], camera: .off, microphone: .systemDefault, systemAudio: .off))
        #expect(QuickSettings().framesPerSecond(display: 3) == 60 && QuickSettings().displayScale == .native)
        #expect(QuickSettings().windowFramesPerSecond == 60)
        #expect(QuickSettings().cameraPreset == .p1080 && QuickSettings().cameraFramesPerSecond == 30)
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
        let plan = try TakePlanner.plan(
            selection, settings: settings, displays: Self.displays, granted: Self.allGranted, includedWindowIDs: [77],
            factory: factory)

        #expect(TakePlanner.problem(with: selection, displays: Self.displays) == nil)
        #expect(plan.sources.map(\.trackID) == ["display-2", "display-1", "mic"])
        #expect(plan.sources.map(\.media) == [.video(framesPerSecond: 30), .video(framesPerSecond: 60), .audio])
        #expect(factory.calls == [
            .display(id: 2, framesPerSecond: 30, scale: .points, area: nil, includedWindowIDs: [77]),
            .display(id: 1, framesPerSecond: 60, scale: .points, area: nil, includedWindowIDs: [77]),
            .microphone(.systemDefault),
            .input(windowTrack: nil, displayIDs: [2, 1]),
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
        #expect(factory.calls.last == .input(windowTrack: nil, displayIDs: [1, 2]))
    }

    @Test func planUsesTheChosenMicrophoneOnlyWhenGranted() throws {
        var selection = CaptureSelection.mainDisplay(1)
        selection.microphone = .device(uniqueID: "usb-1")
        let factory = FakeFactory()
        let plan = try TakePlanner.plan(selection, settings: QuickSettings(), displays: Self.displays, granted: Self.allGranted, factory: factory)
        #expect(factory.calls == [
            .display(id: 1, framesPerSecond: 60, scale: .native, area: nil, includedWindowIDs: []),
            .microphone(.device(uniqueID: "usb-1")), .input(windowTrack: nil, displayIDs: [1]),
        ])
        let microphone = try #require(plan.optional.first)
        #expect(plan.optional.count == 1 && plan.sources.last === microphone)
        // Metered inside: the source the take tracks is the one it measures.
        let meter = try #require(plan.microphoneMeter)
        #expect(microphone.base === meter && meter.base === factory.microphones.first && factory.microphones.count == 1)

        var off = selection
        off.microphone = .off
        let cases: [(CaptureSelection, Set<PermissionKind>, Set<TrackKind>)] = [
            (off, Self.allGranted, []), (selection, [.screenRecording], []), (selection, Self.allGranted, [.microphone]),
        ]
        for (selection, granted, skipping) in cases {
            let factory = FakeFactory()
            let plan = try TakePlanner.plan(
                selection, settings: QuickSettings(), displays: Self.displays, granted: granted, skipping: skipping, factory: factory)
            #expect(plan.sources.map(\.trackID) == ["display-1"])
            #expect(plan.optional.isEmpty && plan.microphoneMeter == nil)
            #expect(factory.calls == [
                .display(id: 1, framesPerSecond: 60, scale: .native, area: nil, includedWindowIDs: []),
                .input(windowTrack: nil, displayIDs: [1]),
            ])
        }
    }

    @Test func planRefusesWithoutAScreen() {
        var noScreen = CaptureSelection.mainDisplay(1)
        noScreen.displayIDs = []
        var areaOnAMissingDisplay = CaptureSelection.mainDisplay(1)
        areaOnAMissingDisplay.mode = .area
        areaOnAMissingDisplay.area = AreaChoice(displayID: 9, rect: Rect(x: 0, y: 0, width: 640, height: 360))
        let cases: [(CaptureSelection, TakePlanError)] = [
            (noScreen, .noScreenChosen), (.mainDisplay(9), .displayNotFound(9)), (areaOnAMissingDisplay, .displayNotFound(9)),
        ]
        for (selection, expected) in cases {
            let factory = FakeFactory()
            #expect(throws: expected) {
                try TakePlanner.plan(selection, settings: QuickSettings(), displays: Self.displays, granted: Self.allGranted, factory: factory)
            }
            #expect(TakePlanner.problem(with: selection, displays: Self.displays) == expected)
            #expect(factory.calls.isEmpty)
        }
    }

    @Test func planRefusesWithoutAWindowOrAnArea() {
        var window = CaptureSelection.mainDisplay(1)
        window.mode = .window
        window.windowID = nil
        var area = CaptureSelection.mainDisplay(1)
        area.mode = .area
        area.area = nil
        for (selection, expected) in [(window, TakePlanError.noWindowChosen), (area, .noAreaChosen)] {
            let factory = FakeFactory()
            #expect(throws: expected) {
                try TakePlanner.plan(selection, settings: QuickSettings(), displays: Self.displays, granted: Self.allGranted, factory: factory)
            }
            #expect(TakePlanner.problem(with: selection, displays: Self.displays) == expected)
            #expect(factory.calls.isEmpty)
        }
    }

    @Test func planForAreaRecordsTheWholeDisplayWithTheArea() throws {
        var selection = CaptureSelection.mainDisplay(2)
        selection.mode = .area
        selection.area = AreaChoice(displayID: 1, rect: Rect(x: 100, y: 100, width: 800, height: 450))
        selection.microphone = .off
        let factory = FakeFactory()
        let plan = try TakePlanner.plan(
            selection, settings: QuickSettings(framesPerSecondByDisplay: [1: 30]), displays: Self.displays, granted: Self.allGranted,
            includedWindowIDs: [77], factory: factory)

        #expect(TakePlanner.problem(with: selection, displays: Self.displays) == nil)
        #expect(plan.sources.map(\.trackID) == ["display-1"])
        #expect(factory.calls == [
            .display(id: 1, framesPerSecond: 30, scale: .native, area: Rect(x: 100, y: 100, width: 800, height: 450), includedWindowIDs: [77]),
            .input(windowTrack: nil, displayIDs: [1]),
        ])
        // The whole display is recorded: the encoder carries all of it.
        #expect(TakePlanner.loadItems(selection, settings: QuickSettings(framesPerSecondByDisplay: [1: 30]), displays: Self.displays, windowSize: nil)
            == [VideoLoadItem(source: .display(1), width: 3024, height: 1964, framesPerSecond: 30)])
    }

    @Test func planForWindowUsesTheWindowSourceAndGeometryRecorder() throws {
        var selection = CaptureSelection.mainDisplay(1)
        selection.mode = .window
        selection.windowID = 4242
        selection.microphone = .off
        let factory = FakeFactory()
        let settings = QuickSettings(displayScale: .points, windowFramesPerSecond: 30)
        let plan = try TakePlanner.plan(selection, settings: settings, displays: Self.displays, granted: Self.allGranted, factory: factory)

        #expect(TakePlanner.problem(with: selection, displays: Self.displays) == nil)
        #expect(plan.sources.map(\.trackID) == ["window-4242"])
        #expect(plan.sources.map(\.kind) == [.window] && plan.optional.isEmpty)
        // The window is made first: what records its geometry asks that window when its last frame came.
        #expect(factory.calls == [
            .window(id: 4242, framesPerSecond: 30, scale: .points),
            .input(windowTrack: .init(trackID: "window-4242", windowID: 4242), displayIDs: []),
        ])
        // The window counts with the size its source gives (64 × 36 at one pixel per point).
        #expect(plan.load == .ok(ratio: Double(64 * 36 * 30) / Double(EncoderLoad.defaultBudgetPixelsPerSecond)))
    }

    @Test func planAddsCameraMicAndSystemAudioWhenChosenAndGranted() throws {
        var selection = CaptureSelection.mainDisplay(1)
        selection.camera = .device(uniqueID: "camera-1")
        selection.systemAudio = .applications(["com.example.app"])
        let settings = QuickSettings(cameraPreset: .p720, cameraFramesPerSecond: 60)
        let factory = FakeFactory()
        let plan = try TakePlanner.plan(selection, settings: settings, displays: Self.displays, granted: Self.allGranted, factory: factory)
        #expect(plan.sources.map(\.trackID) == ["display-1", "camera", "mic", "system-audio-com-example-app"])
        #expect(plan.optional.map(\.kind) == [.camera, .microphone, .systemAudio])
        #expect(plan.sources.count == 4 && zip(plan.sources.dropFirst(), plan.optional).allSatisfy { $0 === $1 })
        #expect(factory.calls == [
            .display(id: 1, framesPerSecond: 60, scale: .native, area: nil, includedWindowIDs: []),
            .camera(.device(uniqueID: "camera-1"), preset: .p720, framesPerSecond: 60),
            .microphone(.systemDefault),
            .systemAudio(SystemAudioTrackPlan(
                trackID: "system-audio-com-example-app", scope: .applications(["com.example.app"]), appBundleID: "com.example.app")),
            .input(windowTrack: nil, displayIDs: [1]),
        ])
        #expect(plan.optional.map(\.base).first === factory.cameras.first)

        // Without the camera's permission there is no camera; system audio skipped is left out.
        let without = FakeFactory()
        let partial = try TakePlanner.plan(
            selection, settings: settings, displays: Self.displays, granted: [.screenRecording, .microphone, .systemAudio],
            skipping: [.systemAudio], factory: without)
        #expect(partial.sources.map(\.trackID) == ["display-1", "mic"])
        #expect(partial.optional.map(\.kind) == [.microphone])
        #expect(without.cameras.isEmpty && without.systemAudios.isEmpty)
        // Nor does the camera weigh on the encoder.
        #expect(partial.load == .ok(ratio: Double(3024 * 1964 * 60) / Double(EncoderLoad.defaultBudgetPixelsPerSecond)))
        // Without system audio's permission there is none either.
        let noSystemAudio = try TakePlanner.plan(
            selection, settings: settings, displays: Self.displays, granted: [.screenRecording, .camera], factory: FakeFactory())
        #expect(noSystemAudio.sources.map(\.trackID) == ["display-1", "camera"])
    }

    // Phase 3 (plan 3c, Task U9, decision 1): By App records each app in a track of its own.
    @Test func byAppPlansOneSourcePerApp() throws {
        var selection = CaptureSelection.mainDisplay(1)
        selection.systemAudio = .applications(["com.apple.Safari", "dev.toma.Toma", "com.spotify.client"])
        let factory = FakeFactory()
        let plan = try TakePlanner.plan(
            selection, settings: QuickSettings(), displays: Self.displays, granted: Self.allGranted,
            ownBundleIdentifier: "dev.toma.Toma", factory: factory)
        #expect(plan.sources.map(\.trackID) == ["display-1", "mic", "system-audio-com-apple-Safari", "system-audio-com-spotify-client"])
        #expect(plan.optional.map(\.kind) == [.microphone, .systemAudio, .systemAudio])
        #expect(zip(plan.sources.dropFirst(), plan.optional).allSatisfy { $0 === $1 })
        #expect(factory.calls == [
            .display(id: 1, framesPerSecond: 60, scale: .native, area: nil, includedWindowIDs: []),
            .microphone(.systemDefault),
            .systemAudio(SystemAudioTrackPlan(
                trackID: "system-audio-com-apple-Safari", scope: .applications(["com.apple.Safari"]), appBundleID: "com.apple.Safari",
                otherApplications: ["com.spotify.client"])),
            .systemAudio(SystemAudioTrackPlan(
                trackID: "system-audio-com-spotify-client", scope: .applications(["com.spotify.client"]),
                appBundleID: "com.spotify.client", otherApplications: ["com.apple.Safari"])),
            .input(windowTrack: nil, displayIDs: [1]),
        ])
        #expect(plan.sources.map(\.sourceInfo).suffix(2) == [
            TrackSource(name: "com.apple.Safari", includedBundleIDs: ["com.apple.Safari"]),
            TrackSource(name: "com.spotify.client", includedBundleIDs: ["com.spotify.client"]),
        ])
        // Skipped (a tap that did not start), none of them.
        let skipped = try TakePlanner.plan(
            selection, settings: QuickSettings(), displays: Self.displays, granted: Self.allGranted, skipping: [.systemAudio],
            ownBundleIdentifier: "dev.toma.Toma", factory: FakeFactory())
        #expect(skipped.sources.map(\.trackID) == ["display-1", "mic"])
        #expect(SystemAudioChoice.off.scope == nil)
        #expect(SystemAudioChoice.all.scope == .all)
        #expect(SystemAudioChoice.applications(["a"]).scope == .applications(["a"]))
    }

    @Test func allStaysOneTrack() throws {
        var selection = CaptureSelection.mainDisplay(1)
        selection.systemAudio = .all
        let factory = FakeFactory()
        let plan = try TakePlanner.plan(selection, settings: QuickSettings(), displays: Self.displays, granted: Self.allGranted, factory: factory)
        #expect(plan.sources.map(\.trackID) == ["display-1", "mic", "system-audio"])
        #expect(factory.calls.filter { if case .systemAudio = $0 { true } else { false } }
            == [.systemAudio(SystemAudioTrackPlan(trackID: "system-audio", scope: .all, appBundleID: nil))])
        // By App with no app is one track too, of silence.
        selection.systemAudio = .applications([])
        let none = try TakePlanner.plan(selection, settings: QuickSettings(), displays: Self.displays, granted: Self.allGranted, factory: FakeFactory())
        #expect(none.sources.map(\.trackID) == ["display-1", "mic", "system-audio"])
    }

    @Test func loadItemsFollowTheSelectionAndTheSettings() {
        var selection = CaptureSelection.mainDisplay(1)
        selection.displayIDs = [2, 1, 2]
        selection.camera = .systemDefault
        let settings = QuickSettings(
            framesPerSecondByDisplay: [2: 30], displayScale: .points, cameraPreset: .p2160, cameraFramesPerSecond: 24)
        #expect(TakePlanner.loadItems(selection, settings: settings, displays: Self.displays, windowSize: nil) == [
            VideoLoadItem(source: .display(2), width: 1920, height: 1080, framesPerSecond: 30),
            VideoLoadItem(source: .display(1), width: 1512, height: 982, framesPerSecond: 60),
            VideoLoadItem(source: .camera, width: 3840, height: 2160, framesPerSecond: 24),
        ])

        var window = CaptureSelection.mainDisplay(1)
        window.mode = .window
        window.windowID = 7
        let windowSettings = QuickSettings(windowFramesPerSecond: 30)
        #expect(TakePlanner.loadItems(window, settings: windowSettings, displays: Self.displays, windowSize: CGSize(width: 2400, height: 1600))
            == [VideoLoadItem(source: .window, width: 2400, height: 1600, framesPerSecond: 30)])
        // A window whose size is not known yet weighs nothing.
        #expect(TakePlanner.loadItems(window, settings: windowSettings, displays: Self.displays, windowSize: nil).isEmpty)
    }

    @Test func planTellsTheEncoderLoadWithTheBudgetGiven() throws {
        var selection = CaptureSelection.mainDisplay(1)
        selection.displayIDs = [1, 2]
        let plan = try TakePlanner.plan(
            selection, settings: QuickSettings(), displays: Self.displays, granted: Self.allGranted, factory: FakeFactory(),
            budget: 550_000_000)
        let pixels = 3024 * 1964 * 60 + 1920 * 1080 * 60
        #expect(plan.load == .high(ratio: Double(pixels) / 550_000_000, suggestions: [.lowerDisplayRate(displayID: 2, to: 30)]))
    }
}

/// Makes synthetic sources, and records what it was asked for in order: a 64 × 36 display per display
/// ID, a 64 × 36 window, a 64 × 36 camera that fails its first `cameraFailures` starts, a microphone that fails
/// its first `microphoneFailures` starts, system audio, a 36 × 64 iPhone with its sound, and no input.
final class FakeFactory: CaptureSourceFactory {
    /// The window track `input` is asked to follow.
    struct WindowTrack: Equatable {
        var trackID: String
        var windowID: UInt32
    }

    enum Call: Equatable {
        case display(id: UInt32, framesPerSecond: Int, scale: CaptureScale, area: Rect?, includedWindowIDs: [UInt32])
        case window(id: UInt32, framesPerSecond: Int, scale: CaptureScale)
        case camera(DeviceChoice, preset: CameraPreset, framesPerSecond: Int)
        case microphone(DeviceChoice)
        case systemAudio(SystemAudioTrackPlan)
        case input(windowTrack: WindowTrack?, displayIDs: [UInt32])
        case device(uniqueID: String)
    }

    /// How many times each new display fails to start.
    var displayFailures = 0
    /// How many times each new microphone fails to start.
    var microphoneFailures = 0
    /// How many times each new camera fails to start.
    var cameraFailures = 0
    private(set) var calls: [Call] = []
    /// What was made, oldest first.
    private(set) var microphones: [SyntheticAudioSource] = []
    private(set) var cameras: [SyntheticVideoSource] = []
    private(set) var windows: [SyntheticVideoSource] = []
    private(set) var systemAudios: [SyntheticAudioSource] = []
    /// The iPhones' screens and sounds, in pairs.
    private(set) var devices: [(video: SyntheticVideoSource, audio: SyntheticAudioSource)] = []

    func display(id: UInt32, framesPerSecond: Int, scale: CaptureScale, area: Rect?, includedWindowIDs: [UInt32]) -> any CaptureSource {
        calls.append(.display(id: id, framesPerSecond: framesPerSecond, scale: scale, area: area, includedWindowIDs: includedWindowIDs))
        let display = SyntheticVideoSource(trackID: "display-\(id)", width: 64, height: 36, framesPerSecond: framesPerSecond)
        display.failOnStart = displayFailures
        return display
    }

    /// The synthetic window always says its ID is 4242.
    func window(id: UInt32, framesPerSecond: Int, scale: CaptureScale) -> any CaptureSource {
        calls.append(.window(id: id, framesPerSecond: framesPerSecond, scale: scale))
        let window = SyntheticVideoSource(trackID: "window-\(id)", kind: .window, width: 64, height: 36, framesPerSecond: framesPerSecond)
        windows.append(window)
        return window
    }

    func camera(_ choice: DeviceChoice, preset: CameraPreset, framesPerSecond: Int) -> any CaptureSource {
        calls.append(.camera(choice, preset: preset, framesPerSecond: framesPerSecond))
        let camera = SyntheticVideoSource(trackID: "camera", kind: .camera, width: 64, height: 36, framesPerSecond: framesPerSecond)
        camera.failOnStart = cameraFailures
        cameras.append(camera)
        return camera
    }

    func microphone(_ choice: DeviceChoice) -> any CaptureSource {
        calls.append(.microphone(choice))
        let microphone = SyntheticAudioSource()
        microphone.failOnStart = microphoneFailures
        microphones.append(microphone)
        return microphone
    }

    /// An app's track is named after its bundle ID.
    func systemAudio(_ track: SystemAudioTrackPlan) -> any CaptureSource {
        calls.append(.systemAudio(track))
        let systemAudio = SyntheticAudioSource(
            trackID: track.trackID, kind: .systemAudio, app: track.appBundleID.map { (bundleID: $0, name: $0) })
        systemAudios.append(systemAudio)
        return systemAudio
    }

    /// The iPhone's screen at 60 fps, as the app records it.
    func device(uniqueID: String) -> (video: any CaptureSource, audio: any CaptureSource) {
        calls.append(.device(uniqueID: uniqueID))
        let video = SyntheticVideoSource(trackID: "device", kind: .device, width: 36, height: 64, framesPerSecond: 60)
        video.deviceUniqueID = uniqueID
        let audio = SyntheticAudioSource(trackID: "deviceAudio", kind: .deviceAudio)
        audio.deviceUniqueID = uniqueID
        devices.append((video, audio))
        return (video, audio)
    }

    func input(windowTrack: (trackID: String, windowID: UInt32)?, displayIDs: [UInt32]) -> any InputRecorder {
        calls.append(.input(windowTrack: windowTrack.map { WindowTrack(trackID: $0.trackID, windowID: $0.windowID) }, displayIDs: displayIDs))
        return NoInputRecorder()
    }
}
