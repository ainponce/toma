// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// What "Re-record from Here" needs and may not find (plan 3d, decision 9): the screen (the displays, the area, the
/// window or the iPhone), the camera and the microphone of the take under the playhead.
public enum RerecordSource: Hashable, Sendable {
    case screen, camera, microphone
}

/// What a re-record records: the take's sources that are still there (`selection`), and the ones that are not
/// (`missing`), which the island asks for. With none missing, the re-record starts at once.
public struct RerecordChoice: Equatable, Sendable {
    public var selection: CaptureSelection
    public var missing: Set<RerecordSource>

    public init(selection: CaptureSelection, missing: Set<RerecordSource>) {
        self.selection = selection
        self.missing = missing
    }
}

/// The selection that records again what a take recorded (phase 3 design §8.2: "the same source, camera and
/// microphone of the take under the playhead").
public enum RerecordSelection {
    /// The sources of `take`, as its tracks say, among those connected now: an iPhone or iPad among `devices` (its
    /// `uniqueID`); else the window, if the window server's window of that number (`window`, its app now) is still the
    /// same app's (by bundle ID, or by name for an app without one); else the area of a display or the displays, in track
    /// order, among `displays`. The camera and the microphone are their `uniqueID` among `cameras` and `microphones`
    /// (the default one for a track that did not know its device, if there is one), `.off` without a track. System
    /// audio records every app, or the apps of its tracks in their order (the one app of each track of 3c, then the
    /// rest), and is never missing. A screen, camera or microphone the take had and that is not found is `missing`, and
    /// left out of the selection (the island chooses it).
    public static func choice(
        for take: TakeRecord, displays: Set<UInt32>, window: (UInt32) -> WindowOwner?, cameras: Set<String>,
        microphones: Set<String>, devices: Set<String>
    ) -> RerecordChoice {
        var missing: Set<RerecordSource> = []
        var selection = CaptureSelection(mode: .display, displayIDs: [], camera: .off, microphone: .off, systemAudio: .off)
        let tracks = take.tracks
        if let device = tracks.first(where: { $0.kind == .device }) {
            selection.mode = .device
            if let id = device.source.deviceUniqueID, devices.contains(id) {
                selection.deviceUniqueID = id
            } else {
                missing.insert(.screen)
            }
        } else if let recorded = tracks.first(where: { $0.kind == .window }) {
            selection.mode = .window
            if let id = recorded.source.windowID, let owner = window(id), isSameApp(owner, as: recorded.source) {
                selection.windowID = id
                selection.windowOwner = owner
            } else {
                missing.insert(.screen)
            }
        } else {
            let screens = tracks.filter { $0.kind == .display }
            if let area = screens.first(where: { $0.source.captureArea != nil }) {
                selection.mode = .area
                if let id = area.source.displayID, let rect = area.source.captureArea, displays.contains(id) {
                    selection.area = AreaChoice(displayID: id, rect: rect)
                } else {
                    missing.insert(.screen)
                }
            } else {
                let recorded = screens.compactMap(\.source.displayID)
                selection.displayIDs = recorded.filter(displays.contains)
                if recorded.isEmpty || selection.displayIDs.count < recorded.count { missing.insert(.screen) }
            }
        }
        if let camera = device(of: tracks, .camera, among: cameras) {
            selection.camera = camera
        } else {
            missing.insert(.camera)
        }
        if let microphone = device(of: tracks, .microphone, among: microphones) {
            selection.microphone = microphone
        } else {
            missing.insert(.microphone)
        }
        selection.systemAudio = systemAudio(of: tracks)
        return RerecordChoice(selection: selection, missing: missing)
    }

    /// Whether `owner`, the app of the window now, is the one whose window `source` recorded.
    private static func isSameApp(_ owner: WindowOwner, as source: TrackSource) -> Bool {
        if let bundleID = source.bundleIdentifier { return owner.bundleID == bundleID }
        // A window's track is named "<app> — <title>", or the app alone (`WindowCaptureSource.sourceInfo`).
        return owner.bundleID == nil && (source.name == owner.name || source.name.hasPrefix(owner.name + " — "))
    }

    /// The choice that records the device of the first track of `kind` again: `.off` without one; `nil` if its device is
    /// not among `connected` (or, for a track that did not know it, no device is).
    private static func device(of tracks: [TrackRecord], _ kind: TrackKind, among connected: Set<String>) -> DeviceChoice? {
        guard let track = tracks.first(where: { $0.kind == kind }) else { return .off }
        guard let id = track.source.deviceUniqueID else { return connected.isEmpty ? nil : .systemDefault }
        return connected.contains(id) ? .device(uniqueID: id) : nil
    }

    /// Every app, if a track of system audio recorded every app; otherwise the apps its tracks recorded, in track order,
    /// each once; `.off` without one.
    private static func systemAudio(of tracks: [TrackRecord]) -> SystemAudioChoice {
        let recorded = tracks.filter { $0.kind == .systemAudio }
        guard !recorded.isEmpty else { return .off }
        var apps: [String] = []
        for track in recorded {
            guard let included = track.source.includedBundleIDs ?? track.appBundleID.map({ [$0] }) else { return .all }
            for app in included where !apps.contains(app) { apps.append(app) }
        }
        return .applications(apps)
    }
}
