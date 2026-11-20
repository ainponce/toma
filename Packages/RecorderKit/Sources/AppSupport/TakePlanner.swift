// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ProjectFormat
import Recording

/// Makes the sources of a take: the real ones in the app, synthetic ones in tests.
public protocol CaptureSourceFactory {
    /// The whole display; `area` (global points) is the part of it chosen in Area mode, and `includedWindowIDs` the
    /// windows of this app the recording keeps.
    func display(id: UInt32, framesPerSecond: Int, scale: CaptureScale, area: Rect?, includedWindowIDs: [UInt32]) -> any CaptureSource
    func window(id: UInt32, framesPerSecond: Int, scale: CaptureScale) -> any CaptureSource
    /// Never called with `.off`: the plan then has no camera.
    func camera(_ choice: DeviceChoice, preset: CameraPreset, framesPerSecond: Int) -> any CaptureSource
    /// Never called with `.off`: the plan then has no microphone.
    func microphone(_ choice: DeviceChoice) -> any CaptureSource
    /// One track of system audio (`SystemAudioTracks.plan`): all of the system, one app, or the apps past the seventh.
    func systemAudio(_ track: SystemAudioTrackPlan) -> any CaptureSource
    /// What records the take's input: the cursor, the geometry of `displayIDs` and, in Window mode, where the window
    /// of `windowTrack` is. Called after the take's sources are made, so the window's source is the one `window`
    /// made for that ID. Never called in `.device` mode: nothing of the Mac's input is recorded.
    func input(windowTrack: (trackID: String, windowID: UInt32)?, displayIDs: [UInt32]) -> any InputRecorder
    /// The screen (`device` track, at `TakePlanner.deviceFramesPerSecond`) and the sound (`deviceAudio`) of the iPhone
    /// or iPad `uniqueID` connected by cable, sharing its one capture. Made on the main actor, they ask the device
    /// nothing until the take's coordinator reads them off it.
    func device(uniqueID: String) -> (video: any CaptureSource, audio: any CaptureSource)
}

/// The sources of a take, in track order, and what records its input.
public struct TakePlan {
    public var sources: [any CaptureSource]
    /// The sources in `sources` the take can do without (the camera, the microphone, system audio): if one fails to
    /// start, the take is recorded again without it (`OptionalSourceFallback`).
    public var optional: [StartTrackingSource]
    public var input: any InputRecorder
    /// How much of the encoder's budget the video tracks would use.
    public var load: EncoderLoadVerdict
    /// The microphone as it was made, inside the `StartTrackingSource` of `sources`: it says how loud it is.
    public var microphoneMeter: MeteredSource? = nil

    public init(
        sources: [any CaptureSource], optional: [StartTrackingSource], input: any InputRecorder, load: EncoderLoadVerdict,
        microphoneMeter: MeteredSource? = nil
    ) {
        self.sources = sources
        self.optional = optional
        self.input = input
        self.load = load
        self.microphoneMeter = microphoneMeter
    }
}

/// Why a selection cannot be recorded.
public enum TakePlanError: Error, Equatable {
    /// Display mode without a display.
    case noScreenChosen
    /// A chosen display (or the display of the area) is not connected.
    case displayNotFound(UInt32)
    /// Window mode without a window.
    case noWindowChosen
    /// Area mode without an area.
    case noAreaChosen
    /// iPhone mode without an iPhone or iPad.
    case noDeviceChosen
}

extension SystemAudioChoice {
    /// What system audio records, `nil` when it is off.
    public var scope: SystemAudioScope? {
        switch self {
        case .off: nil
        case .all: .all
        case .applications(let bundleIDs): .applications(bundleIDs)
        }
    }
}

/// Turns what the user chose into the sources of a take.
public enum TakePlanner {
    /// The frame rate an iPhone or iPad is recorded at: its screen's own.
    public static let deviceFramesPerSecond = 60
    /// What an iPhone or iPad weighs on the encoder while its size is not known: the largest screen one sends (an iPad
    /// Pro of 13 in, upright). A device tells its size only once its first run has started, and is never asked on
    /// the main thread, where the take is planned.
    public static let unknownDeviceSize = CGSize(width: 2064, height: 2752)

    /// The sources, in track order (the manifest's): the displays in the order of `selection.displayIDs` (each
    /// once), at their frame rate; or the display of the area, whole, with the area; or the window, at
    /// `windowFramesPerSecond`; all at the display scale of `settings`; or the screen and then the sound of the iPhone
    /// or iPad (`factory.device`), which need no permission here (the take's check wants the camera's). Then the
    /// camera (at `cameraPreset` and `cameraFramesPerSecond`), the microphone (metered: `microphoneMeter`) and system
    /// audio, each only when it is chosen, its permission is in `granted` and its kind is not in `skipping`, and each in
    /// `optional`. System audio is one source per track of `SystemAudioTracks.plan` (By App, one per app but
    /// `ownBundleIdentifier`), in its order: one that fails to start skips them all. `includedWindowIDs` go to every
    /// display. The input is `factory.input`'s, or none for a device. The load is that of what the plan records (`loadItems`, with the window's size as its source gives it, a device at
    /// `unknownDeviceSize`) against `budget`.
    public static func plan(
        _ selection: CaptureSelection,
        settings: QuickSettings,
        displays: [DisplayInfo],
        granted: Set<PermissionKind>,
        skipping: Set<TrackKind> = [],
        includedWindowIDs: [UInt32] = [],
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        factory: any CaptureSourceFactory,
        budget: Int = EncoderLoad.defaultBudgetPixelsPerSecond
    ) throws -> TakePlan {
        if let problem = problem(with: selection, displays: displays) { throw problem }
        var sources: [any CaptureSource]
        var windowTrack: (trackID: String, windowID: UInt32)?
        var windowSize: CGSize?
        var recordsInput = true
        let inputDisplayIDs: [UInt32]
        switch selection.mode {
        case .display:
            inputDisplayIDs = uniqueDisplayIDs(of: selection)
            sources = inputDisplayIDs.map { id in
                factory.display(
                    id: id, framesPerSecond: settings.framesPerSecond(display: id), scale: settings.displayScale, area: nil,
                    includedWindowIDs: includedWindowIDs)
            }
        case .area:
            guard let area = selection.area else { throw TakePlanError.noAreaChosen }
            inputDisplayIDs = [area.displayID]
            sources = [
                factory.display(
                    id: area.displayID, framesPerSecond: settings.framesPerSecond(display: area.displayID),
                    scale: settings.displayScale, area: area.rect, includedWindowIDs: includedWindowIDs),
            ]
        case .window:
            guard let windowID = selection.windowID else { throw TakePlanError.noWindowChosen }
            inputDisplayIDs = []
            let window = factory.window(id: windowID, framesPerSecond: settings.windowFramesPerSecond, scale: settings.displayScale)
            sources = [window]
            windowTrack = (window.trackID, windowID)
            windowSize = pixelSize(of: window.sourceInfo)
        case .device:
            // Its `sourceInfo` is never read here: finding the device takes a while, and is not done on the main thread.
            guard let uniqueID = selection.deviceUniqueID else { throw TakePlanError.noDeviceChosen }
            inputDisplayIDs = []
            let device = factory.device(uniqueID: uniqueID)
            sources = [device.video, device.audio]
            recordsInput = false
        }

        func records(_ kind: TrackKind, chosen: Bool, permission: PermissionKind) -> Bool {
            chosen && granted.contains(permission) && !skipping.contains(kind)
        }
        var optional: [StartTrackingSource] = []
        func add(_ source: any CaptureSource) {
            let tracked = StartTrackingSource(source)
            sources.append(tracked)
            optional.append(tracked)
        }
        let recordsCamera = records(.camera, chosen: selection.camera != .off, permission: .camera)
        if recordsCamera {
            add(factory.camera(selection.camera, preset: settings.cameraPreset, framesPerSecond: settings.cameraFramesPerSecond))
        }
        var microphoneMeter: MeteredSource?
        if records(.microphone, chosen: selection.microphone != .off, permission: .microphone) {
            let meter = MeteredSource(factory.microphone(selection.microphone))
            add(meter)
            microphoneMeter = meter
        }
        if records(.systemAudio, chosen: selection.systemAudio != .off, permission: .systemAudio),
            let scope = selection.systemAudio.scope
        {
            for track in SystemAudioTracks.plan(scope, ownBundleIdentifier: ownBundleIdentifier) {
                add(factory.systemAudio(track))
            }
        }

        var recorded = selection
        if !recordsCamera { recorded.camera = .off }
        let load = EncoderLoad.evaluate(
            loadItems(recorded, settings: settings, displays: displays, windowSize: windowSize),
            mainDisplayID: displays.first(where: \.isMain)?.id, budget: budget)
        // An iPhone's take records nothing of the Mac's input: no cursor, no keys, no geometry of a display.
        let input = recordsInput ? factory.input(windowTrack: windowTrack, displayIDs: inputDisplayIDs) : NoInputRecorder()
        return TakePlan(sources: sources, optional: optional, input: input, load: load, microphoneMeter: microphoneMeter)
    }

    /// The video tracks `selection` records with `settings`, in track order, as the encoder sees them: each display
    /// (the whole display of an area) at its pixels (`DisplayInfo.scale` per point, or one at `.points`) and frame
    /// rate; the window at `windowSize` (pixels) and `windowFramesPerSecond`, if its size is known; the iPhone or iPad
    /// at `deviceSize` (pixels; `unknownDeviceSize` while it is not known) and `deviceFramesPerSecond`; the camera, if
    /// it is not off, at `cameraPreset` and `cameraFramesPerSecond`. A display that is not connected weighs nothing.
    public static func loadItems(
        _ selection: CaptureSelection, settings: QuickSettings, displays: [DisplayInfo], windowSize: CGSize?,
        deviceSize: CGSize? = nil
    ) -> [VideoLoadItem] {
        var items: [VideoLoadItem] = []
        func addDisplay(_ id: UInt32) {
            guard let display = displays.first(where: { $0.id == id }) else { return }
            let pixelsPerPoint = settings.displayScale == .points ? 1 : display.scale
            items.append(VideoLoadItem(
                source: .display(id), width: Int((display.frame.width * pixelsPerPoint).rounded()),
                height: Int((display.frame.height * pixelsPerPoint).rounded()), framesPerSecond: settings.framesPerSecond(display: id)))
        }
        switch selection.mode {
        case .display:
            uniqueDisplayIDs(of: selection).forEach(addDisplay)
        case .area:
            if let area = selection.area { addDisplay(area.displayID) }
        case .window:
            if let windowSize {
                items.append(VideoLoadItem(
                    source: .window, width: Int(windowSize.width.rounded()), height: Int(windowSize.height.rounded()),
                    framesPerSecond: settings.windowFramesPerSecond))
            }
        case .device:
            let size = deviceSize ?? unknownDeviceSize
            items.append(VideoLoadItem(
                source: .device, width: Int(size.width.rounded()), height: Int(size.height.rounded()),
                framesPerSecond: deviceFramesPerSecond))
        }
        if selection.camera != .off {
            items.append(VideoLoadItem(
                source: .camera, width: settings.cameraPreset.width, height: settings.cameraPreset.height,
                framesPerSecond: settings.cameraFramesPerSecond))
        }
        return items
    }

    /// What keeps `selection` from being recorded with `displays` connected, whatever the permissions:
    /// the check `plan` makes first. `nil` when it can be recorded.
    public static func problem(with selection: CaptureSelection, displays: [DisplayInfo]) -> TakePlanError? {
        let connected = Set(displays.map(\.id))
        switch selection.mode {
        case .display:
            guard !selection.displayIDs.isEmpty else { return .noScreenChosen }
            if let missing = selection.displayIDs.first(where: { !connected.contains($0) }) {
                return .displayNotFound(missing)
            }
        case .window:
            guard selection.windowID != nil else { return .noWindowChosen }
        case .area:
            guard let area = selection.area else { return .noAreaChosen }
            guard connected.contains(area.displayID) else { return .displayNotFound(area.displayID) }
        case .device:
            // Whether it is connected is the device's to say as the take starts (`CaptureSourceError.deviceNotFound`).
            guard selection.deviceUniqueID != nil else { return .noDeviceChosen }
        }
        return nil
    }

    /// `selection.displayIDs` without repeats: a display is one track.
    private static func uniqueDisplayIDs(of selection: CaptureSelection) -> [UInt32] {
        var seen = Set<UInt32>()
        return selection.displayIDs.filter { seen.insert($0).inserted }
    }

    /// The pixels a window's track records now: its frame in points by its pixels per point.
    private static func pixelSize(of window: TrackSource) -> CGSize? {
        guard let frame = window.globalFrame else { return nil }
        let scale = window.pixelScale ?? 1
        return CGSize(width: frame.width * scale, height: frame.height * scale)
    }
}
