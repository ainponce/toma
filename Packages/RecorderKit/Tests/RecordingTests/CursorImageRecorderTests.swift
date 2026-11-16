// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing
@testable import Recording

@Suite struct CursorImageRecorderTests {
    /// A cursor that is whatever the test last set: `nil` is a macOS that gives none.
    final class FakeCursor: SystemCursorSource {
        private let snapshot = Mutex<CursorSnapshot?>(nil)

        func set(_ value: CursorSnapshot?) {
            snapshot.withLock { $0 = value }
        }

        @MainActor func current() -> CursorSnapshot? {
            snapshot.withLock { $0 }
        }
    }

    /// A clock that moves only when the test says, one second at a time.
    final class ManualClock: Sendable {
        private let time = Mutex(HostTime(nanoseconds: 1_000_000_000_000))

        var now: HostTime { time.withLock { $0 } }

        func advance() {
            time.withLock { $0 = $0.adding(seconds: 1) }
        }
    }

    /// A recorder of `cursor` on manual ticks and a manual clock, writing to `take-001/events.jsonl` in `dir`.
    struct Rig {
        let takeDirectory: URL
        let log: EventLogWriter
        let cursor = FakeCursor()
        let clock = ManualClock()
        let ticks = ManualTicks()
        let recorder: CursorImageRecorder

        init(in dir: URL, kinds: CursorKindMatcher = CursorKindMatcher(references: [:])) throws {
            takeDirectory = dir.appendingPathComponent("take-001", isDirectory: true)
            try FileManager.default.createDirectory(at: takeDirectory, withIntermediateDirectories: false)
            log = try EventLogWriter(url: takeDirectory.appendingPathComponent("events.jsonl"))
            let clock = clock
            recorder = CursorImageRecorder(source: cursor, kinds: kinds, clock: { clock.now }, ticks: ticks.ticks)
        }

        var cursorsDirectory: URL { takeDirectory.appendingPathComponent("cursors", isDirectory: true) }

        /// One second later, `snapshot` is the cursor and the recorder samples it.
        func show(_ snapshot: CursorSnapshot?) async {
            clock.advance()
            cursor.set(snapshot)
            await ticks.fire(every: CursorImageRecorder.interval)
        }

        /// Stops the recorder, closes the log and returns its `cursorImage` events in file order.
        func finish() async throws -> [(t: HostTime, hash: String, hotspot: SIMD2<Double>, size: SIMD2<Double>, kind: CursorKind?)] {
            await recorder.stop()
            try log.close()
            return try EventLogReader.read(log.url).events.compactMap { event in
                guard case let .cursorImage(hash, hotspot, size, kind) = event.kind else { return nil }
                return (event.t, hash, hotspot, size, kind)
            }
        }

        /// The names in `cursors/`, sorted; empty without the folder.
        func savedImages() throws -> [String] {
            guard FileManager.default.fileExists(atPath: cursorsDirectory.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(atPath: cursorsDirectory.path).sorted()
        }
    }

    /// A cursor of `pointSize` points filled with `rgba` (premultiplied), drawn at 4×.
    static func snapshot(
        _ rgba: [UInt8], pointSize: SIMD2<Double> = [24, 32], hotspot: SIMD2<Double> = [4, 6], fingerprint: UInt64
    ) throws -> CursorSnapshot {
        let width = Int(pointSize.x * 4), height = Int(pointSize.y * 4)
        let bytes = (0..<(width * height)).flatMap { _ in rgba }
        return CursorSnapshot(image: try image(width: width, height: height, rgba: bytes), pointSize: pointSize, hotspot: hotspot, fingerprint: fingerprint)
    }

    /// An sRGB image with these premultiplied RGBA bytes, top row first.
    static func image(width: Int, height: Int, rgba: [UInt8]) throws -> CGImage {
        let provider = try unwrap(CGDataProvider(data: Data(rgba) as CFData), "data provider")
        return try unwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: try unwrap(CGColorSpace(name: CGColorSpace.sRGB), "sRGB"),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent), "image")
    }

    static let red: [UInt8] = [255, 0, 0, 255]
    static let blue: [UInt8] = [0, 0, 255, 255]
    static let green: [UInt8] = [0, 128, 0, 128]

    @Test func writesAnImageOnlyWhenItChanges() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try Rig(in: dir)
            let a = try Self.snapshot(Self.red, fingerprint: 1)
            let b = try Self.snapshot(Self.blue, fingerprint: 2)
            rig.cursor.set(a)
            await rig.recorder.start(log: rig.log)  // samples A at once
            let first = rig.clock.now
            await rig.show(a)
            await rig.show(b)
            let second = rig.clock.now
            await rig.show(b)
            await rig.show(a)
            let third = rig.clock.now
            let events = try await rig.finish()

            let (hashA, hashB) = (CursorImageHash.hash(a), CursorImageHash.hash(b))
            #expect(hashA != hashB)
            #expect(events.map(\.hash) == [hashA, hashB, hashA])
            #expect(events.map(\.t) == [first, second, third])
            #expect(try rig.savedImages() == [hashA + ".png", hashB + ".png"].sorted())
        }
    }

    @Test func imageIsFourTimesItsPointSize() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try Rig(in: dir)
            let snapshot = try await MainActor.run { () throws -> CursorSnapshot in
                let image = NSImage(size: NSSize(width: 24, height: 32), flipped: false) { rect in
                    NSColor.red.setFill()
                    rect.fill()
                    return true
                }
                return try unwrap(CursorSnapshot(cursor: NSCursor(image: image, hotSpot: NSPoint(x: 4, y: 6))), "snapshot")
            }
            #expect(snapshot.pointSize == [24, 32])
            #expect(snapshot.hotspot == [4, 6])
            rig.cursor.set(snapshot)
            await rig.recorder.start(log: rig.log)
            let events = try await rig.finish()

            let event = try #require(events.first)
            #expect(events.count == 1)
            let png = try Data(contentsOf: rig.cursorsDirectory.appendingPathComponent(event.hash + ".png"))
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 96)
            #expect(image.height == 128)
            #expect(event.size == [24, 32])
            // The drawing is there, not an empty image of the right size.
            #expect(CursorImageHash.rgbaPixels(of: image)[(64 * 96 + 48) * 4 + 3] == 255)
        }
    }

    @Test func hashIsTheDocumentedDigest() throws {
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 128, 0, 128, 0, 0, 0, 0, 10, 20, 30, 40]
        let image = try Self.image(width: 2, height: 2, rgba: pixels)
        let snapshot = CursorSnapshot(image: image, pointSize: [0.5, 0.5], hotspot: [0.25, 0.125], fingerprint: 7)

        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(2).littleEndian) { bytes += $0 }
        withUnsafeBytes(of: Int32(2).littleEndian) { bytes += $0 }
        withUnsafeBytes(of: (0.25 as Double).bitPattern.littleEndian) { bytes += $0 }
        withUnsafeBytes(of: (0.125 as Double).bitPattern.littleEndian) { bytes += $0 }
        bytes += pixels
        let expected = SHA256.hash(data: bytes).prefix(16).map { String(format: "%02x", $0) }.joined()

        #expect(CursorImageHash.hash(snapshot) == expected)
        #expect(expected.count == 32)
        // The fingerprint and the size in points are not part of it.
        let other = CursorSnapshot(image: image, pointSize: [2, 2], hotspot: [0.25, 0.125], fingerprint: 8)
        #expect(CursorImageHash.hash(other) == expected)
    }

    @Test func kindIsSetOnlyForMatchingCursors() async throws {
        try await withTemporaryDirectory { dir in
            let matcher = CursorKindMatcher(references: [10: .iBeam, 20: .resizeLeftRight, 21: .resizeLeftRight])
            let iBeam = try Self.snapshot(Self.red, fingerprint: 10)
            let edge = try Self.snapshot(Self.blue, fingerprint: 20)
            let column = try Self.snapshot(Self.green, fingerprint: 21)
            let own = try Self.snapshot([1, 2, 3, 4], fingerprint: 99)
            #expect(matcher.kind(of: iBeam) == .iBeam)
            #expect(matcher.kind(of: edge) == .resizeLeftRight)
            #expect(matcher.kind(of: column) == .resizeLeftRight)
            #expect(matcher.kind(of: own) == nil)

            let rig = try Rig(in: dir, kinds: matcher)
            rig.cursor.set(iBeam)
            await rig.recorder.start(log: rig.log)
            await rig.show(edge)
            await rig.show(column)
            await rig.show(own)
            let events = try await rig.finish()
            #expect(events.map(\.kind) == [.iBeam, .resizeLeftRight, .resizeLeftRight, nil])

            let lines = try String(contentsOf: rig.log.url, encoding: .utf8).split(separator: "\n")
            let ownLine = try #require(lines.first { $0.contains(CursorImageHash.hash(own)) })
            #expect(!ownLine.contains("\"kind\""))
            #expect(lines.first { $0.contains(CursorImageHash.hash(iBeam)) }?.contains("\"kind\":\"iBeam\"") == true)
        }
    }

    @Test func hotspotIsAFractionAndSizeInPoints() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try Rig(in: dir)
            rig.cursor.set(try Self.snapshot(Self.red, pointSize: [24, 32], hotspot: [4, 6], fingerprint: 1))
            await rig.recorder.start(log: rig.log)
            let events = try await rig.finish()
            let event = try #require(events.first)
            #expect(abs(event.hotspot.x - 4.0 / 24) < 1e-12)
            #expect(event.hotspot.y == 0.1875)
            #expect(event.size == [24, 32])
        }
    }

    @Test func nothingWhilePaused() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try Rig(in: dir)
            let a = try Self.snapshot(Self.red, fingerprint: 1)
            let b = try Self.snapshot(Self.blue, fingerprint: 2)
            let c = try Self.snapshot(Self.green, fingerprint: 3)
            rig.cursor.set(a)
            await rig.recorder.start(log: rig.log)
            await rig.recorder.pause()
            await rig.recorder.pause()  // idempotent
            await rig.show(b)
            rig.cursor.set(c)
            await rig.recorder.resume()  // samples C at once
            await rig.recorder.resume()  // idempotent: one timer, not two
            await rig.show(c)
            let events = try await rig.finish()

            #expect(events.map(\.hash) == [CursorImageHash.hash(a), CursorImageHash.hash(c)])
            #expect(!(try rig.savedImages()).contains(CursorImageHash.hash(b) + ".png"))
            #expect(try rig.savedImages().count == 2)
        }
    }

    @Test func noCursorFromTheSystemWritesNothing() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try Rig(in: dir)
            await rig.recorder.start(log: rig.log)
            await rig.show(nil)
            await rig.show(nil)
            let events = try await rig.finish()
            #expect(events.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: rig.cursorsDirectory.path))
        }
    }

    @Test func existingFileIsKept() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try Rig(in: dir)
            let a = try Self.snapshot(Self.red, fingerprint: 1)
            let hash = CursorImageHash.hash(a)
            try FileManager.default.createDirectory(at: rig.cursorsDirectory, withIntermediateDirectories: false)
            let existing = rig.cursorsDirectory.appendingPathComponent(hash + ".png")
            try Data("kept".utf8).write(to: existing)

            rig.cursor.set(a)
            await rig.recorder.start(log: rig.log)
            let events = try await rig.finish()
            #expect(events.map(\.hash) == [hash])
            #expect(try Data(contentsOf: existing) == Data("kept".utf8))
            #expect(rig.recorder.imagesWritten == 0)
        }
    }

    @Test func eachShapeIsWrittenOncePerTake() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try Rig(in: dir)
            let a = try Self.snapshot(Self.red, fingerprint: 1)
            let b = try Self.snapshot(Self.blue, fingerprint: 2)
            rig.cursor.set(a)
            await rig.recorder.start(log: rig.log)
            await rig.show(b)
            await rig.show(a)
            await rig.show(b)
            await rig.show(a)
            let events = try await rig.finish()
            #expect(events.count == 5)
            #expect(rig.recorder.imagesWritten == 2)
            #expect(try rig.savedImages().count == 2)
        }
    }

    @MainActor @Test func liveMatcherKnowsTodaysResizeCursors() throws {
        let matcher = CursorKindMatcher.makeLive()
        func kind(_ cursor: NSCursor) throws -> CursorKind? {
            matcher.kind(of: try unwrap(CursorSnapshot(cursor: cursor), "snapshot"))
        }
        #expect(try kind(.frameResize(position: .left, directions: .all)) == .resizeLeftRight)
        #expect(try kind(.frameResize(position: .right, directions: .outward)) == .resizeLeftRight)
        #expect(try kind(.frameResize(position: .top, directions: .all)) == .resizeUpDown)
        #expect(try kind(.columnResize(directions: .all)) == .resizeLeftRight)
        #expect(try kind(.rowResize(directions: .all)) == .resizeUpDown)
        #expect(try kind(.rowResize(directions: .up)) == .resizeUpDown)
        #expect(try kind(.pointingHand) == .pointingHand)
        #expect(try kind(.frameResize(position: .topLeft, directions: .all)) == nil)
        #expect(try kind(.frameResize(position: .bottomRight, directions: .inward)) == nil)
    }

    /// `TakeBuilder` names a cursor image by the recorder's hash and logs it as the recorder does.
    @Test func takeBuilderAddsACursorImageByItsHash() throws {
        try withTemporaryDirectory { dir in
            let builder = try TakeBuilder(in: dir)
            let image = try Self.image(width: 96, height: 128, rgba: (0..<(96 * 128)).flatMap { _ in Self.red })
            let png = try CursorImageRecorder.pngData(image)
            let t = HostTime(nanoseconds: 5_000_000_000)
            let hash = try builder.addCursorImage(png, hotspot: [0.5, 0.25], size: [24, 32], kind: .iBeam, at: t)
            let project = try builder.write()

            let snapshot = CursorSnapshot(image: image, pointSize: [24, 32], hotspot: [12, 8], fingerprint: 0)
            #expect(hash == CursorImageHash.hash(snapshot))
            #expect(project.events.contains(InputEvent(t: t, kind: .cursorImage(hash: hash, hotspot: [0.5, 0.25], size: [24, 32], kind: .iBeam))))
            #expect(try Data(contentsOf: builder.package.cursorImageURL(take: "take-001", hash: hash)) == png)
        }
    }
}
