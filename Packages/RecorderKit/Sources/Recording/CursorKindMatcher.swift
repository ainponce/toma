// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ProjectFormat

/// Which system cursor a recorded cursor is, by its fingerprint (`CursorSnapshot.fingerprint`): the `kind` of its
/// `cursorImage` event, so Toma's style can draw its own cursor of that shape. Several fingerprints can give the same
/// kind; one that matches none has no kind, and the editor shows the recorded image.
public struct CursorKindMatcher: Sendable {
    private let references: [UInt64: CursorKind]

    public init(references: [UInt64: CursorKind]) {
        self.references = references
    }

    /// The fingerprints of this Mac's own cursors. Built on the main actor, where AppKit draws them, when a take starts
    /// (never in a lazy `static let`, which any thread could start): the arrow, the I-beam, the hands, the crosshair,
    /// "not allowed", the resize cursors of today (`resizeLeftRight`, `resizeUpDown`, which the SDK marks
    /// `API_TO_BE_DEPRECATED`) and those of macOS 15 and later: `frameResize` at the 4 edges in every set of directions
    /// (left and right are `resizeLeftRight`, top and bottom `resizeUpDown`), `columnResize` (`resizeLeftRight`) and
    /// `rowResize` (`resizeUpDown`). The diagonal ones of the 4 corners have no kind (design §7.5): the editor shows the
    /// recorded image. If two kinds had the same fingerprint, the first one listed would win.
    ///
    /// In a process without an `NSApplication` (a command-line tool, the tests) AppKit gives `nil` for the arrow and the
    /// I-beam, although the SDK says they are never `nil`: they are left out there. Every cursor is also taken as an
    /// optional, so any other one AppKit gave as `nil` would be skipped alone, not end the list.
    @MainActor public static func makeLive() -> CursorKindMatcher {
        var cursors: [(NSCursor?, CursorKind)] = []
        if NSApp != nil {
            cursors += [(NSCursor.arrow, .arrow), (NSCursor.iBeam, .iBeam)]
        }
        cursors += [
            (NSCursor.pointingHand, .pointingHand), (NSCursor.openHand, .openHand), (NSCursor.closedHand, .closedHand),
            (NSCursor.crosshair, .crosshair), (NSCursor.operationNotAllowed, .notAllowed),
            (NSCursor.resizeLeftRight, .resizeLeftRight), (NSCursor.resizeUpDown, .resizeUpDown),
        ]
        let directions: [NSCursor.FrameResizeDirection.Set] = [.all, .inward, .outward]
        for position: NSCursor.FrameResizePosition in [.left, .right] {
            cursors += directions.map { (NSCursor.frameResize(position: position, directions: $0), .resizeLeftRight) }
        }
        for position: NSCursor.FrameResizePosition in [.top, .bottom] {
            cursors += directions.map { (NSCursor.frameResize(position: position, directions: $0), .resizeUpDown) }
        }
        cursors += [NSHorizontalDirection.Set.all, .left, .right].map { (NSCursor.columnResize(directions: $0), .resizeLeftRight) }
        cursors += [NSVerticalDirection.Set.all, .up, .down].map { (NSCursor.rowResize(directions: $0), .resizeUpDown) }

        var references: [UInt64: CursorKind] = [:]
        for (cursor, kind) in cursors {
            guard let cursor, let fingerprint = CursorSnapshot.fingerprint(of: cursor), references[fingerprint] == nil
            else { continue }
            references[fingerprint] = kind
        }
        return CursorKindMatcher(references: references)
    }

    /// The kind of the system cursor with `snapshot`'s fingerprint, or `nil` if it is none of them.
    public func kind(of snapshot: CursorSnapshot) -> CursorKind? {
        references[snapshot.fingerprint]
    }
}
