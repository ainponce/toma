// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import RecorderKitTestSupport
import Synchronization
import Testing
import UniformTypeIdentifiers
// Not @testable: the app uses only the public API.
import Analysis
import Editing
import ProjectFormat

/// What the tests of this file share.
private enum NewDocumentFixture {
    static let base = HostTime(nanoseconds: 5_000_000_000_000)

    /// `c-00000001`, `c-00000002`… from 1 for each new instance.
    final class IDs: Sendable {
        private let count = Mutex(0)

        func make(_ prefix: String) -> String {
            count.withLock { count in
                count += 1
                return prefix + String(format: "%08x", count)
            }
        }
    }

    static func display(_ id: UInt32, _ frame: Rect) -> TrackSource {
        TrackSource(name: "Synthetic Display \(id)", displayID: id, globalFrame: frame, pixelScale: 1)
    }

    /// A take of 2 s with `screens` displays side by side, 640 × 360 pt each: the cursor on the first for 1 s, with a
    /// click at 0.5 s, then on the last.
    static func take(
        in dir: URL, name: String = "Fixture", screens: Int, cursorImage: Bool = false
    ) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: name)
        var geometry: [InputEvent] = []
        for index in 0..<screens {
            let id = UInt32(index + 1)
            let frame = Rect(x: 640 * Double(index), y: 0, width: 640, height: 360)
            try await builder.addVideoTrack(
                id: "display-\(id)", source: display(id, frame), segments: [VideoSegmentSpec(start: base, seconds: 2, framesPerSecond: 10)])
            geometry.append(InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: id, frame: frame, scale: 1)))
        }
        try builder.addEvents(geometry)
        let lastX = 640 * Double(screens - 1) + 300
        try builder.addEvents((0..<40).map { i in
            InputEvent(t: base.adding(seconds: Double(i) / 20), kind: .cursor(x: i < 20 ? 200 : lastX, y: 180))
        })
        try builder.addEvents([
            InputEvent(t: base.adding(seconds: 0.5), kind: .mouseDown(.left, x: 200, y: 180)),
            InputEvent(t: base.adding(seconds: 0.55), kind: .mouseUp(.left, x: 200, y: 180)),
        ])
        if cursorImage {
            try builder.addCursorImage(try png(), hotspot: SIMD2(0.1, 0.1), size: SIMD2(16, 16), at: base.adding(seconds: 0.1))
        }
        return try builder.write()
    }

    /// A 32 × 32 PNG, filled.
    static func png() throws -> Data {
        guard let context = CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw TestSupportError.failed("no context") }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 4, y: 4, width: 20, height: 24))
        guard let image = context.makeImage() else { throw TestSupportError.failed("no image") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw TestSupportError.failed("no destination") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestSupportError.failed("no PNG") }
        return data as Data
    }
}

@Test func newDocumentClosesPauses() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await GoldenProjects.make("pausedTake", in: dir, formatVersion: 3)
        let document = NewDocument.make(project: project, defaultStyle: .toma, makeID: NewDocumentFixture.IDs().make)
        let segments = try #require(project.take.track("display-1")).segments
        let ranges: [Range<HostTime>] = try segments.map { $0.startHostTime..<(try #require($0.endHostTime)) }
        #expect(ranges.count == 2)
        #expect(document.sequence.map { $0.start..<$0.end } == ranges)
        #expect(document.sequence.map { $0.start..<$0.end } == TakeTimeline.recordedSpans(take: project.take, events: project.events))
        // [0, 1) and [2, 3) s of the take.
        let start = ranges[0].lowerBound
        #expect(ranges.map { $0.lowerBound.seconds(since: start) } == [0, 2])
        #expect(ranges.map { $0.upperBound.seconds(since: start) } == [1, 3])
        #expect(document.sequence.map(\.id) == ["c-00000001", "c-00000002"])
        #expect(document.sequence.allSatisfy { $0.speed == 1 && $0.take == project.take.id })
        #expect(document.logSequence == 0)
    }
}

@Test func newDocumentUsesTheDefaultStyleAndThePlanners() async throws {
    try await withTemporaryDirectory { dir in
        let style = DefaultStyle.toma
        for screens in [1, 2] {
            let project = try await NewDocumentFixture.take(in: dir, name: "screens-\(screens)", screens: screens)
            let document = NewDocument.make(project: project, defaultStyle: style, makeID: NewDocumentFixture.IDs().make)
            let legacy = EditDocument.legacy(for: project)
            #expect(document.documentVersion == EditDocument.currentVersion)
            #expect(document.aspect == .landscape)
            #expect(document.frameRate == 60)
            var stage = style.style
            stage.screenSampling = .mipmapped
            stage.geometryTransition = .spring
            #expect(document.style == stage)
            #expect(document.zoom.show == style.zoomShow)
            #expect(document.zoom.auto == style.zoomAuto)
            #expect(document.zoom.spring == style.zoomSpring)
            #expect(document.zoom.motionBlur == style.zoomMotionBlur)
            #expect(document.zoom.suppressed.isEmpty)
            // The automatic blocks of the document as it is.
            #expect(!document.zoom.regions.isEmpty)
            #expect(document.zoom.regions == AutoZoomPlanner.plan(take: project.take, events: project.events, document: document))
            #expect(document.camera == legacy.camera)
            #expect(document.audio == AudioPlan(limiter: true, tracks: legacy.audio.tracks))
            let plan = ScreenFollowPlanner.plan(take: project.take, events: project.events, package: project.package)
            #expect(document.screens.initial == ["take-001": "display-1"])
            if screens == 2 {
                #expect(document.screens.planner == "screenFollow-1")
                #expect(!plan.changes.isEmpty)
                #expect(document.screens.changes == plan.changes)
            } else {
                #expect(document.screens.planner == nil)
                #expect(document.screens.changes.isEmpty)
            }
        }
    }
}

@Test func cursorStyleIsTomaWithoutRecordedImages() async throws {
    try await withTemporaryDirectory { dir in
        let without = try await NewDocumentFixture.take(in: dir, name: "without", screens: 1)
        let with = try await NewDocumentFixture.take(in: dir, name: "with", screens: 1, cursorImage: true)
        let plain = NewDocument.make(project: without, defaultStyle: .toma, makeID: NewDocumentFixture.IDs().make)
        let recorded = NewDocument.make(project: with, defaultStyle: .toma, makeID: NewDocumentFixture.IDs().make)
        #expect(plain.cursor.style == .toma)
        #expect(recorded.cursor.style == .system)
        // Everything else of the cursor is the default style's.
        var cursor = DefaultStyle.toma.cursor
        cursor.style = .toma
        #expect(plain.cursor == cursor)
    }
}
