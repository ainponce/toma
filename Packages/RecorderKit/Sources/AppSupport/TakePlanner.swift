// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
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
    /// Never called with `.off`: the plan then has no system audio.
    func systemAudio(_ choice: SystemAudioChoice) -> any CaptureSource
    /// What records the take's input: the cursor, the geometry of `displayIDs` and, in Window mode, where the window
    /// of `windowTrack` is. Called after the take's sources are made, so the window's source is the one `window`
    /// made for that ID.
    func input(windowTrack: (trackID: String, windowID: UInt32)?, displayIDs: [UInt32]) -> any InputRecorder
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
}

/// Turns what the user chose into the sources of a take.
public enum TakePlanner {
    /// The sources, in track order (the manifest's): the displays in the order of `selection.displayIDs` (each
    /// once), at their frame rate; or the display of the area, whole, with the area; or the window, at
    /// `windowFramesPerSecond`; all at the display scale of `settings`. Then the camera (at `cameraPreset` and
    /// `cameraFramesPerSecond`), the microphone (metered: `microphoneMeter`) and system audio, each only when it is
    /// chosen, its permission is in `granted` and its kind is not in `skipping`, and each in `optional`.
    /// `includedWindowIDs` go to every display. The load is that of what the plan records (`loadItems`, with the
    /// window's size as its source gives it) against `budget`.
    public static func plan(
        _ selection: CaptureSelection,
        settings: QuickSettings,
        displays: [DisplayInfo],
        granted: Set<PermissionKind>,
        skipping: Set<TrackKind> = [],
        includedWindowIDs: [UInt32] = [],
        factory: any CaptureSourceFactory,
        budget: Int = EncoderLoad.defaultBudgetPixelsPerSecond
    ) throws -> TakePlan {
        if let problem = problem(with: selection, displays: displays) { throw problem }
        var sources: [any CaptureSource]
        var windowTrack: (trackID: String, windowID: UInt32)?
        var windowSize: CGSize?
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
        if records(.systemAudio, chosen: selection.systemAudio != .off, permission: .systemAudio) {
            add(factory.systemAudio(selection.systemAudio))
        }

        var recorded = selection
        if !recordsCamera { recorded.camera = .off }
        let load = EncoderLoad.evaluate(
            loadItems(recorded, settings: settings, displays: displays, windowSize: windowSize),
            mainDisplayID: displays.first(where: \.isMain)?.id, budget: budget)
        return TakePlan(
            sources: sources, optional: optional, input: factory.input(windowTrack: windowTrack, displayIDs: inputDisplayIDs),
            load: load, microphoneMeter: microphoneMeter)
    }

    /// The video tracks `selection` records with `settings`, in track order, as the encoder sees them: each display
    /// (the whole display of an area) at its pixels (`DisplayInfo.scale` per point, or one at `.points`) and frame
    /// rate; the window at `windowSize` (pixels) and `windowFramesPerSecond`, if its size is known; the camera, if it
    /// is not off, at `cameraPreset` and `cameraFramesPerSecond`. A display that is not connected weighs nothing.
    public static func loadItems(
        _ selection: CaptureSelection, settings: QuickSettings, displays: [DisplayInfo], windowSize: CGSize?
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
