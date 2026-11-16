// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum MouseButton: String, Codable, Sendable {
    case left, right, other
}

/// A system cursor a `cursorImage` event can say its image is: the shapes Toma can draw in its own style.
/// A `kind` this version does not know reads as none, so a newer version can add shapes.
public enum CursorKind: String, Codable, Sendable, CaseIterable {
    case arrow, iBeam, pointingHand, openHand, closedHand, crosshair, resizeLeftRight, resizeUpDown, notAllowed
}

/// One line of `events.jsonl`: something that happened at host time `t` during a take.
///
/// Encoded flat, with `t`, `type` and the fields of its kind at the same level:
/// `{"t":123,"type":"cursor","x":10.5,"y":20}`. Positions are in global points, the space
/// of `CGEvent.location` and of `TrackSource.globalFrame`: origin at the top left of the
/// main display, `y` growing down, negative on displays left of or above the main one.
public struct InputEvent: Codable, Equatable, Sendable {
    public var t: HostTime
    public var kind: Kind

    public init(t: HostTime, kind: Kind) {
        self.t = t
        self.kind = kind
    }

    public enum Kind: Equatable, Sendable {
        /// The pointer is at (`x`, `y`).
        case cursor(x: Double, y: Double)
        case mouseDown(MouseButton, x: Double, y: Double)
        case mouseUp(MouseButton, x: Double, y: Double)
        /// Where a display is (`frame`, in global points) and its pixels per point.
        case displayGeometry(displayID: UInt32, frame: Rect, scale: Double)
        /// `track` opened segment `index`; `t` is the segment's `startHostTime`.
        case segmentStarted(track: String, index: Int)
        /// The capture stream of `track` failed with this error.
        case streamInterrupted(track: String, domain: String, code: Int)
        /// Capture stopped for every track, for example with `reason` `screenLocked`.
        case paused(reason: String)
        /// Capture started again after `paused`.
        case resumed
        /// `track` went on recording from another device.
        case deviceChanged(track: String, deviceUniqueID: String)
        /// A mark the user placed while recording.
        case marker
        /// `count` samples of `track` have been dropped so far in its current segment (the one its last
        /// `segmentStarted` opened): a running total, logged while recording whenever it changes, so
        /// recovery can fill in `droppedFrames` of a segment the recorder never closed.
        case droppedSamples(track: String, count: Int)
        /// Frame `frame` of the file of audio track `track`'s current segment (counted from 0, the frame at
        /// the segment's `startHostTime`) was captured at `t`. The file only counts frames and a device's
        /// clock drifts from the host's, so the recording logs one every few seconds of audio and the export
        /// places the audio by host time through them.
        case audioClock(track: String, frame: Int)
        /// Where the window of window track `track` is (`frame`, in global points), and whether macOS has it on
        /// screen (`onScreen` is `false` both while it is minimized or hidden and while it is on another Space).
        case windowGeometry(track: String, frame: Rect, onScreen: Bool)
        /// The camera looks like this from `t` on: the user moved it or changed its shape or size while
        /// recording. The take's `cameraStyle` is how it looked before the first one.
        case cameraStyle(CameraStyle)
        /// macOS shows this cursor from `t` on (version 3). Its image is `takes/<take>/cursors/<hash>.png`, drawn at 4
        /// times its size in points; `hash` is 32 hex digits of SHA-256 of the image. `hotspot` is where the pointer is
        /// in the image, as a fraction of it from its top left; `size` is the cursor's width (`x`) and height (`y`) in
        /// points. `kind`: the system cursor whose pixels it has, if it is one of them (`nil` otherwise, or a `kind`
        /// this version does not know).
        case cursorImage(hash: String, hotspot: SIMD2<Double>, size: SIMD2<Double>, kind: CursorKind?)
        /// The user scrolled `dx`, `dy` points since the last one (version 3), summed every 1/30 s, with the pointer at
        /// (`x`, `y`) at the end.
        case scroll(dx: Double, dy: Double, x: Double, y: Double)
        /// At least one key was pressed in the 250 ms that start at `t` (version 3). Never which, nor how many.
        case keyActivity
    }

    /// The event as one line of compact JSON with its keys in alphabetical order,
    /// without the line break. Throws `EncodingError` for a non-finite number.
    public func jsonLine() throws -> String {
        String(decoding: try jsonLineData(), as: UTF8.self)
    }

    /// Decodes one line. Throws `DecodingError` for an unknown `type` or a missing field.
    public init(jsonLine: String) throws {
        self = try JSONDecoder().decode(InputEvent.self, from: Data(jsonLine.utf8))
    }

    /// `jsonLine()` as UTF-8 bytes.
    func jsonLineData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private enum CodingKeys: String, CodingKey {
        case t, type, x, y, button, displayID, frame, scale, track, index, domain, code, reason, deviceUniqueID, count
        case onScreen, style, hash, hotspot, size, kind, dx, dy
    }

    /// The keys of `hotspot`.
    private enum PointKeys: String, CodingKey {
        case x, y
    }

    /// The keys of `size`.
    private enum SizeKeys: String, CodingKey {
        case width, height
    }

    private enum EventType: String, Codable {
        case cursor, mouseDown, mouseUp, displayGeometry, segmentStarted, streamInterrupted, paused, resumed, deviceChanged, marker
        case droppedSamples, audioClock, windowGeometry, cameraStyle, cursorImage, scroll, keyActivity
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let t = try container.decode(HostTime.self, forKey: .t)
        let kind: Kind
        switch try container.decode(EventType.self, forKey: .type) {
        case .cursor:
            kind = .cursor(
                x: try container.decode(Double.self, forKey: .x),
                y: try container.decode(Double.self, forKey: .y)
            )
        case .mouseDown:
            kind = .mouseDown(
                try container.decode(MouseButton.self, forKey: .button),
                x: try container.decode(Double.self, forKey: .x),
                y: try container.decode(Double.self, forKey: .y)
            )
        case .mouseUp:
            kind = .mouseUp(
                try container.decode(MouseButton.self, forKey: .button),
                x: try container.decode(Double.self, forKey: .x),
                y: try container.decode(Double.self, forKey: .y)
            )
        case .displayGeometry:
            kind = .displayGeometry(
                displayID: try container.decode(UInt32.self, forKey: .displayID),
                frame: try container.decode(Rect.self, forKey: .frame),
                scale: try container.decode(Double.self, forKey: .scale)
            )
        case .segmentStarted:
            kind = .segmentStarted(
                track: try container.decode(String.self, forKey: .track),
                index: try container.decode(Int.self, forKey: .index)
            )
        case .streamInterrupted:
            kind = .streamInterrupted(
                track: try container.decode(String.self, forKey: .track),
                domain: try container.decode(String.self, forKey: .domain),
                code: try container.decode(Int.self, forKey: .code)
            )
        case .paused:
            kind = .paused(reason: try container.decode(String.self, forKey: .reason))
        case .resumed:
            kind = .resumed
        case .deviceChanged:
            kind = .deviceChanged(
                track: try container.decode(String.self, forKey: .track),
                deviceUniqueID: try container.decode(String.self, forKey: .deviceUniqueID)
            )
        case .marker:
            kind = .marker
        case .droppedSamples:
            kind = .droppedSamples(
                track: try container.decode(String.self, forKey: .track),
                count: try container.decode(Int.self, forKey: .count)
            )
        case .audioClock:
            kind = .audioClock(
                track: try container.decode(String.self, forKey: .track),
                frame: try container.decode(Int.self, forKey: .frame)
            )
        case .windowGeometry:
            kind = .windowGeometry(
                track: try container.decode(String.self, forKey: .track),
                frame: try container.decode(Rect.self, forKey: .frame),
                onScreen: try container.decode(Bool.self, forKey: .onScreen)
            )
        case .cameraStyle:
            kind = .cameraStyle(try container.decode(CameraStyle.self, forKey: .style))
        case .cursorImage:
            let hotspot = try container.nestedContainer(keyedBy: PointKeys.self, forKey: .hotspot)
            let size = try container.nestedContainer(keyedBy: SizeKeys.self, forKey: .size)
            kind = .cursorImage(
                hash: try container.decode(String.self, forKey: .hash),
                hotspot: SIMD2(try hotspot.decode(Double.self, forKey: .x), try hotspot.decode(Double.self, forKey: .y)),
                size: SIMD2(try size.decode(Double.self, forKey: .width), try size.decode(Double.self, forKey: .height)),
                // A shape this version does not know: the recorded image, as without one.
                kind: try container.decodeIfPresent(String.self, forKey: .kind).flatMap(CursorKind.init(rawValue:))
            )
        case .scroll:
            kind = .scroll(
                dx: try container.decode(Double.self, forKey: .dx),
                dy: try container.decode(Double.self, forKey: .dy),
                x: try container.decode(Double.self, forKey: .x),
                y: try container.decode(Double.self, forKey: .y)
            )
        case .keyActivity:
            kind = .keyActivity
        }
        self.init(t: t, kind: kind)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(t, forKey: .t)
        switch kind {
        case let .cursor(x, y):
            try container.encode(EventType.cursor, forKey: .type)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
        case let .mouseDown(button, x, y):
            try container.encode(EventType.mouseDown, forKey: .type)
            try container.encode(button, forKey: .button)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
        case let .mouseUp(button, x, y):
            try container.encode(EventType.mouseUp, forKey: .type)
            try container.encode(button, forKey: .button)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
        case let .displayGeometry(displayID, frame, scale):
            try container.encode(EventType.displayGeometry, forKey: .type)
            try container.encode(displayID, forKey: .displayID)
            try container.encode(frame, forKey: .frame)
            try container.encode(scale, forKey: .scale)
        case let .segmentStarted(track, index):
            try container.encode(EventType.segmentStarted, forKey: .type)
            try container.encode(track, forKey: .track)
            try container.encode(index, forKey: .index)
        case let .streamInterrupted(track, domain, code):
            try container.encode(EventType.streamInterrupted, forKey: .type)
            try container.encode(track, forKey: .track)
            try container.encode(domain, forKey: .domain)
            try container.encode(code, forKey: .code)
        case let .paused(reason):
            try container.encode(EventType.paused, forKey: .type)
            try container.encode(reason, forKey: .reason)
        case .resumed:
            try container.encode(EventType.resumed, forKey: .type)
        case let .deviceChanged(track, deviceUniqueID):
            try container.encode(EventType.deviceChanged, forKey: .type)
            try container.encode(track, forKey: .track)
            try container.encode(deviceUniqueID, forKey: .deviceUniqueID)
        case .marker:
            try container.encode(EventType.marker, forKey: .type)
        case let .droppedSamples(track, count):
            try container.encode(EventType.droppedSamples, forKey: .type)
            try container.encode(track, forKey: .track)
            try container.encode(count, forKey: .count)
        case let .audioClock(track, frame):
            try container.encode(EventType.audioClock, forKey: .type)
            try container.encode(track, forKey: .track)
            try container.encode(frame, forKey: .frame)
        case let .windowGeometry(track, frame, onScreen):
            try container.encode(EventType.windowGeometry, forKey: .type)
            try container.encode(track, forKey: .track)
            try container.encode(frame, forKey: .frame)
            try container.encode(onScreen, forKey: .onScreen)
        case let .cameraStyle(style):
            try container.encode(EventType.cameraStyle, forKey: .type)
            try container.encode(style, forKey: .style)
        case let .cursorImage(hash, hotspot, size, cursorKind):
            try container.encode(EventType.cursorImage, forKey: .type)
            try container.encode(hash, forKey: .hash)
            var point = container.nestedContainer(keyedBy: PointKeys.self, forKey: .hotspot)
            try point.encode(hotspot.x, forKey: .x)
            try point.encode(hotspot.y, forKey: .y)
            var extent = container.nestedContainer(keyedBy: SizeKeys.self, forKey: .size)
            try extent.encode(size.x, forKey: .width)
            try extent.encode(size.y, forKey: .height)
            try container.encodeIfPresent(cursorKind, forKey: .kind)
        case let .scroll(dx, dy, x, y):
            try container.encode(EventType.scroll, forKey: .type)
            try container.encode(dx, forKey: .dx)
            try container.encode(dy, forKey: .dy)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
        case .keyActivity:
            try container.encode(EventType.keyActivity, forKey: .type)
        }
    }
}
