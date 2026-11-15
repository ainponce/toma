// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// What the screen part of a take records.
public enum CaptureMode: String, Codable, Sendable, CaseIterable {
    /// Whole displays (`CaptureSelection.displayIDs`).
    case display
    /// One window (`CaptureSelection.windowID`).
    case window
    /// A rectangle of one display (`CaptureSelection.area`).
    case area
}

/// A rectangle of a display to record.
public struct AreaChoice: Codable, Equatable, Sendable {
    public var displayID: UInt32
    /// In global points, with the origin at the top left of the main display.
    public var rect: Rect

    public init(displayID: UInt32, rect: Rect) {
        self.displayID = displayID
        self.rect = rect
    }
}

/// Which device of a kind (camera, microphone) a take records.
public enum DeviceChoice: Codable, Equatable, Sendable {
    case off
    /// The system's default device when the take starts.
    case systemDefault
    /// The device with this `uniqueID`.
    case device(uniqueID: String)
}

/// Which system audio a take records.
public enum SystemAudioChoice: Codable, Equatable, Sendable {
    case off
    case all
    /// Only the applications with these bundle IDs.
    case applications([String])
}

/// What the user chose to record.
public struct CaptureSelection: Codable, Equatable, Sendable {
    public var mode: CaptureMode
    /// The displays recorded in `.display` mode, in track order.
    public var displayIDs: [UInt32]
    /// The window recorded in `.window` mode.
    public var windowID: UInt32?
    /// The rectangle recorded in `.area` mode.
    public var area: AreaChoice?
    public var camera: DeviceChoice
    public var microphone: DeviceChoice
    public var systemAudio: SystemAudioChoice

    public init(
        mode: CaptureMode,
        displayIDs: [UInt32],
        windowID: UInt32? = nil,
        area: AreaChoice? = nil,
        camera: DeviceChoice,
        microphone: DeviceChoice,
        systemAudio: SystemAudioChoice
    ) {
        self.mode = mode
        self.displayIDs = displayIDs
        self.windowID = windowID
        self.area = area
        self.camera = camera
        self.microphone = microphone
        self.systemAudio = systemAudio
    }

    /// The display alone with the system's microphone: no camera, no system audio.
    public static func mainDisplay(_ displayID: UInt32) -> CaptureSelection {
        CaptureSelection(mode: .display, displayIDs: [displayID], camera: .off, microphone: .systemDefault, systemAudio: .off)
    }
}

/// A connected display, as a take and the island see it.
public struct DisplayInfo: Equatable, Sendable {
    /// Its `CGDirectDisplayID`.
    public var id: UInt32
    /// `CGDisplayBounds`: global points, with the origin at the top left of the main display.
    public var frame: Rect
    /// Pixels per point (2 on Retina).
    public var scale: Double
    /// The display with the menu bar.
    public var isMain: Bool
    public var maximumFramesPerSecond: Int

    public init(id: UInt32, frame: Rect, scale: Double, isMain: Bool, maximumFramesPerSecond: Int) {
        self.id = id
        self.frame = frame
        self.scale = scale
        self.isMain = isMain
        self.maximumFramesPerSecond = maximumFramesPerSecond
    }
}
