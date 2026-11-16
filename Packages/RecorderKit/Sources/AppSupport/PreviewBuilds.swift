// SPDX-License-Identifier: GPL-3.0-or-later

/// Which of the editor's preview builds are shown (plan decision 22, Task 34, final review D-I1). The scene and the sound
/// of a document are built off the main thread, one at a time, a newer request replacing an older one still waiting, so
/// they come back late and some never do. Every request gets the next `Ticket`: of a session revision, or of a gesture's
/// look (the session's document with the gesture's step and look applied, never logged), derived from a session revision
/// while that gesture lasts. A build is shown unless:
/// - an earlier request's: a newer one is on screen already;
/// - of a revision older than the one the playhead is counted in: the newer revision's is on its way (Task 34);
/// - of a gesture that has ended or was given up: the session's revision is on its way, or on screen.
///
/// So while a drag lasts the preview follows it, build after build, and never goes back.
public struct PreviewBuilds: Sendable, Equatable {
    /// One request for a build.
    public struct Ticket: Sendable, Hashable {
        /// Growing with each request.
        public let number: Int
        /// The session revision the document built is, or is derived from.
        public let revision: Int
        /// The gesture whose look it is; `nil` for a session revision.
        public let gesture: Int?
    }

    private var requested = 0
    /// The number of the build shown last.
    private var shown: Int?
    /// The gesture under way, by its number.
    public private(set) var gesture: Int?
    private var gestures = 0

    public init() {}

    /// A gesture starts: its builds are shown while it lasts.
    public mutating func beginGesture() {
        gestures += 1
        gesture = gestures
    }

    /// The gesture ended or was given up: its builds still on their way are never shown.
    public mutating func endGesture() {
        gesture = nil
    }

    /// The ticket of a build of session revision `revision`, or, with `ofGesture` while a gesture lasts, of its look of
    /// that revision.
    public mutating func request(revision: Int, ofGesture: Bool) -> Ticket {
        requested += 1
        return Ticket(number: requested, revision: revision, gesture: ofGesture ? gesture : nil)
    }

    /// Whether the build of `ticket` is shown, with the playhead counted in session revision `playheadRevision` (`nil`
    /// before there is one); if so, it is the one shown from now on.
    public mutating func accepts(_ ticket: Ticket, playheadRevision: Int?) -> Bool {
        if let shown, ticket.number <= shown { return false }
        if let playheadRevision, ticket.revision < playheadRevision { return false }
        if let made = ticket.gesture, made != gesture { return false }
        shown = ticket.number
        return true
    }
}
