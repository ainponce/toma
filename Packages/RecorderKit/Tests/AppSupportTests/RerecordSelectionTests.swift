// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat
import Testing

/// What "Re-record from Here" records (plan 3d, decision 9): the sources of the take under the playhead, those that are
/// still there, and which of the screen, the camera and the microphone are not.
@Suite struct RerecordSelectionTests {
    private static let frame = Rect(x: 0, y: 0, width: 1920, height: 1080)

    private static func track(_ id: String, _ kind: TrackKind, _ source: TrackSource, appBundleID: String? = nil) -> TrackRecord {
        TrackRecord(id: id, kind: kind, source: source, segments: [], appBundleID: appBundleID)
    }

    private static func take(_ tracks: [TrackRecord]) -> TakeRecord {
        TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: tracks)
    }

    private static func display(_ id: UInt32, area: Rect? = nil) -> TrackRecord {
        track("display-\(id)", .display, TrackSource(name: "Display \(id)", displayID: id, globalFrame: frame, captureArea: area))
    }

    private static let microphone = track("mic", .microphone, TrackSource(name: "Mic", deviceUniqueID: "mic-1"))

    /// The choice for `tracks` with `connected` displays, `windows` by their ID, and these cameras, microphones and iPhones.
    private static func choice(
        _ tracks: [TrackRecord], displays: Set<UInt32> = [1, 2], windows: [UInt32: WindowOwner] = [:],
        cameras: Set<String> = ["cam-1"], microphones: Set<String> = ["mic-1"], devices: Set<String> = ["phone-1"]
    ) -> RerecordChoice {
        RerecordSelection.choice(
            for: take(tracks), displays: displays, window: { windows[$0] }, cameras: cameras, microphones: microphones,
            devices: devices)
    }

    @Test func screensFromTheTake() {
        let both = Self.choice([Self.display(2), Self.display(1), Self.microphone])
        #expect(both.selection == CaptureSelection(
            mode: .display, displayIDs: [2, 1], camera: .off, microphone: .device(uniqueID: "mic-1"), systemAudio: .off))
        #expect(both.missing.isEmpty)

        // One of them is no longer connected: the island asks, with the one that is chosen.
        let one = Self.choice([Self.display(2), Self.display(1)], displays: [1])
        #expect(one.selection.mode == .display && one.selection.displayIDs == [1])
        #expect(one.missing == [.screen])

        let none = Self.choice([Self.display(3)])
        #expect(none.selection.displayIDs.isEmpty && none.missing == [.screen])

        // A take without a screen at all (nothing a take records without one) asks for one.
        #expect(Self.choice([Self.microphone]).missing == [.screen])
    }

    @Test func areaWindowAndDevice() {
        let rect = Rect(x: 100, y: 50, width: 800, height: 600)
        let area = Self.choice([Self.display(2, area: rect)])
        #expect(area.selection.mode == .area && area.selection.area == AreaChoice(displayID: 2, rect: rect))
        #expect(area.selection.displayIDs.isEmpty && area.missing.isEmpty)
        let areaGone = Self.choice([Self.display(2, area: rect)], displays: [1])
        #expect(areaGone.selection.mode == .area && areaGone.selection.area == nil && areaGone.missing == [.screen])

        let safari = TrackSource(name: "Safari — Apple", windowID: 77, bundleIdentifier: "com.apple.Safari")
        let owner = WindowOwner(bundleID: "com.apple.Safari", name: "Safari")
        let window = Self.choice([Self.track("window-77", .window, safari)], windows: [77: owner])
        #expect(window.selection.mode == .window && window.selection.windowID == 77 && window.selection.windowOwner == owner)
        #expect(window.missing.isEmpty)
        // The number is now another app's window, or no window's.
        let other = Self.choice(
            [Self.track("window-77", .window, safari)], windows: [77: WindowOwner(bundleID: "com.apple.Notes", name: "Notes")])
        #expect(other.selection.mode == .window && other.selection.windowID == nil && other.selection.windowOwner == nil)
        #expect(other.missing == [.screen])
        #expect(Self.choice([Self.track("window-77", .window, safari)]).missing == [.screen])
        // An app without a bundle ID: by its name, which starts the track's.
        let tool = TrackSource(name: "tool — Output", windowID: 78)
        let byName = Self.choice([Self.track("window-78", .window, tool)], windows: [78: WindowOwner(bundleID: nil, name: "tool")])
        #expect(byName.selection.windowID == 78 && byName.missing.isEmpty)
        let renamed = Self.choice([Self.track("window-78", .window, tool)], windows: [78: WindowOwner(bundleID: nil, name: "toolbox")])
        #expect(renamed.missing == [.screen])

        let phone = Self.track("device", .device, TrackSource(name: "iPhone", deviceUniqueID: "phone-1"))
        let sound = Self.track("deviceAudio", .deviceAudio, TrackSource(name: "iPhone", deviceUniqueID: "phone-1"))
        let device = Self.choice([phone, sound, Self.microphone])
        #expect(device.selection.mode == .device && device.selection.deviceUniqueID == "phone-1" && device.missing.isEmpty)
        let deviceGone = Self.choice([phone, sound], devices: [])
        #expect(deviceGone.selection.mode == .device && deviceGone.selection.deviceUniqueID == nil)
        #expect(deviceGone.missing == [.screen])
    }

    @Test func cameraMicrophoneAndSystemAudio() {
        let camera = Self.track("camera", .camera, TrackSource(name: "Cam", deviceUniqueID: "cam-1"))
        let all = Self.choice([Self.display(1), camera, Self.microphone])
        #expect(all.selection.camera == .device(uniqueID: "cam-1") && all.selection.microphone == .device(uniqueID: "mic-1"))
        #expect(all.missing.isEmpty)

        let gone = Self.choice([Self.display(1), camera, Self.microphone], cameras: [], microphones: ["mic-2"])
        #expect(gone.selection.camera == .off && gone.selection.microphone == .off)
        #expect(gone.missing == [.camera, .microphone])

        // A track that did not know its device (none resolved as it started) took the default one.
        let unknown = Self.track("camera", .camera, TrackSource(name: "Camera"))
        #expect(Self.choice([Self.display(1), unknown]).selection.camera == .systemDefault)
        #expect(Self.choice([Self.display(1), unknown], cameras: []).missing == [.camera])

        // Without a track, off: nothing is missed.
        let bare = Self.choice([Self.display(1)], cameras: [], microphones: [])
        #expect(bare.selection.camera == .off && bare.selection.microphone == .off && bare.selection.systemAudio == .off)
        #expect(bare.missing.isEmpty)

        let everyApp = Self.track(
            "system-audio", .systemAudio, TrackSource(name: "System Audio", excludedBundleIDs: ["dev.toma.Toma"]))
        #expect(Self.choice([Self.display(1), everyApp]).selection.systemAudio == .all)
        let someApps = Self.track(
            "system-audio", .systemAudio, TrackSource(name: "System Audio", includedBundleIDs: ["com.apple.Safari", "com.spotify.client"]))
        #expect(Self.choice([Self.display(1), someApps]).selection.systemAudio == .applications(["com.apple.Safari", "com.spotify.client"]))
        let noApp = Self.track("system-audio", .systemAudio, TrackSource(name: "System Audio", includedBundleIDs: []))
        #expect(Self.choice([Self.display(1), noApp]).selection.systemAudio == .applications([]))

        // A track per app (3c), and the last one sharing the rest: every app, in track order.
        let safari = Self.track(
            "system-audio-com-apple-Safari", .systemAudio, TrackSource(name: "Safari", includedBundleIDs: ["com.apple.Safari"]),
            appBundleID: "com.apple.Safari")
        let music = Self.track(
            "system-audio-com-apple-Music", .systemAudio, TrackSource(name: "Music"), appBundleID: "com.apple.Music")
        let rest = Self.track(
            "system-audio", .systemAudio, TrackSource(name: "System Audio", includedBundleIDs: ["com.a", "com.apple.Safari"]))
        #expect(Self.choice([Self.display(1), safari, music, rest]).selection.systemAudio
            == .applications(["com.apple.Safari", "com.apple.Music", "com.a"]))
        // System audio is never missing: it is the Mac's.
        #expect(Self.choice([Self.display(1), safari], cameras: [], microphones: []).missing.isEmpty)
    }
}
