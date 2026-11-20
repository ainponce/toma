// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// Where the keyboard's focus is at one moment, as `AccessibilityFocusRecorder` gets it from a `FocusSource`: the
/// rectangle of the element with the focus and that of the text cursor in it, in global points with the origin at the
/// top left of the main display (as `CGEvent.location`), and whether the element is a secure field.
///
/// Only rectangles and that one flag: never what the element holds, its value, role, title or app.
public struct FocusReading: Equatable, Sendable {
    /// The focused element's frame; `nil` when nothing has the focus or its frame cannot be read.
    public var element: Rect?
    /// The text cursor's rectangle (its width may be 0); `nil` when the element has no text cursor, it cannot be read,
    /// or the element is secure.
    public var caret: Rect?
    /// Whether the element is a secure field (its role or subrole is `AXSecureTextField`): its cursor is never written.
    public var isSecure: Bool

    public init(element: Rect?, caret: Rect?, isSecure: Bool) {
        self.element = element
        self.caret = caret
        self.isSecure = isSecure
    }
}

/// Where `AccessibilityFocusRecorder` reads the keyboard's focus.
public protocol FocusSource: AnyObject, Sendable {
    /// Calls `handler` on a thread of its own with a reading at once, and another after each change, until `stop()`;
    /// each with the host time the reading started. Returns `false`, and calls nothing, if the focus cannot be read (no
    /// Accessibility). Starting one that is started starts it again, with the new handler.
    func start(handler: @escaping @Sendable (FocusReading, HostTime) -> Void) -> Bool
    /// Reads no more. Never waits for a reading under way, which may still reach the handler. Does nothing unless
    /// started.
    func stop()
}

/// When to read the focus after a change: at once, unless the last reading was less than `interval` ago; then when the
/// interval is over, in one reading for every change until then. So readings are at least `interval` apart (at most 20
/// a second) and the last change of a burst is always read.
struct FocusReadSchedule: Equatable, Sendable {
    /// The least time between two readings, in nanoseconds: 50 ms.
    static let interval: Int64 = 50_000_000

    /// When the last reading started.
    private var lastRead: HostTime?
    /// A reading put off to this time, not started yet.
    private var pending: HostTime?

    /// Something changed at `now`: when to read it, or `nil` if a reading not started yet already covers it.
    mutating func changed(at now: HostTime) -> HostTime? {
        guard pending == nil else { return nil }
        var at = now
        if let lastRead {
            let next = HostTime(nanoseconds: lastRead.nanoseconds &+ UInt64(Self.interval))
            at = max(now, next)
        }
        pending = at
        return at
    }

    /// A reading started at `time`: what changes from now on needs another.
    mutating func didRead(at time: HostTime) {
        lastRead = time
        pending = nil
    }
}
