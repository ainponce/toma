// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// What a stop does once the take is saved ("When Recording Stops", notch design §5.1): the editor opens
/// on it, or nothing activates the app and the island offers what to do next.
public enum AfterStop: String, Codable, Sendable, CaseIterable {
    case openEditor
    case stayHere
}

/// A take a stop (the user's or the disk's) closed and kept, as the island shows it saved.
public struct SavedTake: Equatable, Sendable {
    public var projectURL: URL
    /// The time it recorded, without its pauses.
    public var duration: Duration
    /// The markers written in it.
    public var markers: Int
    /// The kind of each of its tracks, in the project's order.
    public var trackKinds: [TrackKind]
    /// The editor was opened on it.
    public var openedEditor: Bool

    public init(projectURL: URL, duration: Duration, markers: Int, trackKinds: [TrackKind], openedEditor: Bool) {
        self.projectURL = projectURL
        self.duration = duration
        self.markers = markers
        self.trackKinds = trackKinds
        self.openedEditor = openedEditor
    }
}
