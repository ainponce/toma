// SPDX-License-Identifier: GPL-3.0-or-later
import Recording

/// Makes the sources of a take: the real ones in the app, synthetic ones in tests.
public protocol CaptureSourceFactory {
    func display(id: UInt32, framesPerSecond: Int, scale: CaptureScale) -> any CaptureSource
    /// Never called with `.off`: the plan then has no microphone.
    func microphone(_ choice: DeviceChoice) -> any CaptureSource
    func input(displayIDs: [UInt32]) -> any InputRecorder
}

/// The sources of a take, in track order, and what records its input.
public struct TakePlan {
    public var sources: [any CaptureSource]
    /// The sources in `sources` the take can do without (the microphone): if one fails to start, the
    /// take is recorded again without it (`MicrophoneFallback`).
    public var optional: [StartTrackingSource]
    public var input: any InputRecorder
    /// The microphone as it was made, inside the `StartTrackingSource` of `sources`: it says how loud it is.
    public var microphoneMeter: MeteredSource? = nil

    public init(
        sources: [any CaptureSource], optional: [StartTrackingSource], input: any InputRecorder, microphoneMeter: MeteredSource? = nil
    ) {
        self.sources = sources
        self.optional = optional
        self.input = input
        self.microphoneMeter = microphoneMeter
    }
}

/// Why a selection cannot be recorded.
public enum TakePlanError: Error, Equatable {
    /// Display mode without a display.
    case noScreenChosen
    /// A chosen display is not connected.
    case displayNotFound(UInt32)
    /// The selection asks for something this version does not record yet (a window, an area, system
    /// audio): it is refused, never left out without saying so.
    case notAvailableYet
}

/// Turns what the user chose into the sources of a take.
public enum TakePlanner {
    /// The displays in the order of `selection.displayIDs` (each once), at their frame rate and the
    /// display scale of `settings`; then the microphone, if chosen and `.microphone` is granted, also
    /// listed in `optional` and metered (`microphoneMeter`). The camera is not recorded yet: the plan has no
    /// camera, and the controller says so (`TakeNotice.cameraNotRecordedYet`).
    public static func plan(
        _ selection: CaptureSelection,
        settings: QuickSettings,
        displays: [DisplayInfo],
        granted: Set<PermissionKind>,
        factory: any CaptureSourceFactory
    ) throws -> TakePlan {
        if let problem = problem(with: selection, displays: displays) { throw problem }
        let displayIDs = uniqueDisplayIDs(of: selection)
        var sources = displayIDs.map { id in
            factory.display(id: id, framesPerSecond: settings.framesPerSecond(display: id), scale: settings.displayScale)
        }
        var optional: [StartTrackingSource] = []
        var microphoneMeter: MeteredSource?
        if granted.contains(.microphone), selection.microphone != .off {
            let meter = MeteredSource(factory.microphone(selection.microphone))
            let microphone = StartTrackingSource(meter)
            sources.append(microphone)
            optional.append(microphone)
            microphoneMeter = meter
        }
        return TakePlan(
            sources: sources, optional: optional, input: factory.input(displayIDs: displayIDs), microphoneMeter: microphoneMeter)
    }

    /// What keeps `selection` from being recorded with `displays` connected, whatever the permissions:
    /// the check `plan` makes first. `nil` when it can be recorded.
    public static func problem(with selection: CaptureSelection, displays: [DisplayInfo]) -> TakePlanError? {
        switch selection.mode {
        case .display: break
        case .window, .area: return .notAvailableYet
        }
        guard selection.systemAudio == .off else { return .notAvailableYet }
        guard !selection.displayIDs.isEmpty else { return .noScreenChosen }
        let connected = Set(displays.map(\.id))
        if let missing = selection.displayIDs.first(where: { !connected.contains($0) }) {
            return .displayNotFound(missing)
        }
        return nil
    }

    /// `selection.displayIDs` without repeats: a display is one track.
    private static func uniqueDisplayIDs(of selection: CaptureSelection) -> [UInt32] {
        var seen = Set<UInt32>()
        return selection.displayIDs.filter { seen.insert($0).inserted }
    }
}
