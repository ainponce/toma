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
    /// The screen of an iPhone or iPad connected by cable (`CaptureSelection.deviceUniqueID`), with its sound: nothing
    /// of the Mac but its camera, microphone and system audio.
    case device
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
    /// The app of `windowID`, saved with it: a saved window is restored only if it is still that app's
    /// (`WindowOwner.restored`).
    public var windowOwner: WindowOwner?
    /// The rectangle recorded in `.area` mode.
    public var area: AreaChoice?
    public var camera: DeviceChoice
    public var microphone: DeviceChoice
    public var systemAudio: SystemAudioChoice
    /// The iPhone or iPad recorded in `.device` mode (`ExternalDeviceInfo.uniqueID`); `nil` in a selection saved before
    /// there was one to choose.
    public var deviceUniqueID: String? = nil

    public init(
        mode: CaptureMode,
        displayIDs: [UInt32],
        windowID: UInt32? = nil,
        windowOwner: WindowOwner? = nil,
        area: AreaChoice? = nil,
        camera: DeviceChoice,
        microphone: DeviceChoice,
        systemAudio: SystemAudioChoice,
        deviceUniqueID: String? = nil
    ) {
        self.mode = mode
        self.displayIDs = displayIDs
        self.windowID = windowID
        self.windowOwner = windowOwner
        self.area = area
        self.camera = camera
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.deviceUniqueID = deviceUniqueID
    }

    /// The display alone with the system's microphone: no camera, no system audio.
    public static func mainDisplay(_ displayID: UInt32) -> CaptureSelection {
        CaptureSelection(mode: .display, displayIDs: [displayID], camera: .off, microphone: .systemDefault, systemAudio: .off)
    }
}

/// The app whose window Window mode chose (`CaptureSelection.windowOwner`). A `CGWindowID` is never used again while
/// the user is logged in, but the numbers start over after logging out or restarting: the saved number can then be
/// another app's window, the menu bar's or one of this app's own.
public struct WindowOwner: Codable, Equatable, Sendable {
    /// The app's bundle ID; `nil` for a process without one.
    public var bundleID: String?
    /// The app's name, as the window server says it (`WindowCandidate.ownerName`).
    public var name: String

    public init(bundleID: String?, name: String) {
        self.bundleID = bundleID
        self.name = name
    }

    /// `window`, the window the window server has now with the saved number, if it is still one to record of the
    /// app saved (`owner`): an app's ordinary window (layer 0), not this app's (`ownPID`), whose app has the saved
    /// bundle ID (`bundleID` is the one of `window`'s app now) or, for an app without one, the saved name. `nil`
    /// otherwise, also without an owner saved: the window has to be chosen again. Its title is not compared: it
    /// changes with what the window shows.
    public static func restored(_ window: WindowCandidate?, bundleID: String?, saved owner: WindowOwner?, ownPID: Int32) -> WindowCandidate? {
        guard let window, let owner, window.layer == 0, window.ownerPID != ownPID else { return nil }
        let sameApp = owner.bundleID.map { $0 == bundleID } ?? (bundleID == nil && owner.name == window.ownerName)
        return sameApp ? window : nil
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
