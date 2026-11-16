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

    /// A recorder of `cursor` on manual ticks and a manual clock, writing to the `events.jsonl` of `take-001` of a new
    /// package in `dir`.
    struct Rig {
        static let take = "take-001"
        let package: ProjectPackage
        let takeDirectory: URL
        let log: EventLogWriter
        let cursor = FakeCursor()
        let clock = ManualClock()
        let ticks = ManualTicks()
        let recorder: CursorImageRecorder

        init(
            in dir: URL, kinds: CursorKindMatcher = CursorKindMatcher(references: [:]),
            maxImageBytes: Int = PackageFileKind.cursorImage.maxBytes
        ) throws {
            package = try ProjectPackage.create(in: dir, name: "Cursor", app: AppInfo(name: "Tests", version: "0"), now: Date())
            takeDirectory = package.takeDirectory(Self.take)
            try FileManager.default.createDirectory(at: takeDirectory, withIntermediateDirectories: true)
            log = try EventLogWriter(url: package.eventsURL(take: Self.take))
            let clock = clock
            recorder = CursorImageRecorder(
                source: cursor, kinds: kinds, clock: { clock.now }, ticks: ticks.ticks, maxImageBytes: maxImageBytes)
        }

        var cursorsDirectory: URL { package.cursorsDirectory(take: Self.take) }

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

    /// A cursor of `size` points, transparent but for an opaque red square of `corner` points at its top left, with
    /// its hotspot at `hotspot` points from its top left.
    @MainActor static func cursor(size: NSSize, corner: Double, hotspot: NSPoint) -> NSCursor {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.red.setFill()
            NSRect(x: 0, y: rect.height - corner, width: corner, height: corner).fill()
            return true
        }
        return NSCursor(image: image, hotSpot: hotspot)
    }

    /// The alpha of pixel (`x`, `y`) of `image`, from its top left.
    static func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        CursorImageHash.rgbaPixels(of: image)[(y * image.width + x) * 4 + 3]
    }

    /// The image in `cursors/` named `hash`, through the package's reader.
    static func saved(_ hash: String, in rig: Rig) throws -> CGImage {
        try unwrap(rig.package.cursorImage(take: Rig.take, hash: hash), "cursor image \(hash)")
    }

    @Test func imageIsFourTimesItsPointSize() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try Rig(in: dir)
            let snapshot = try await MainActor.run {
                try unwrap(
                    CursorSnapshot(cursor: Self.cursor(size: NSSize(width: 24, height: 32), corner: 8, hotspot: NSPoint(x: 4, y: 6))),
                    "snapshot")
            }
            #expect(snapshot.pointSize == [24, 32])
            #expect(snapshot.hotspot == [4, 6])
            rig.cursor.set(snapshot)
            await rig.recorder.start(log: rig.log)
            let events = try await rig.finish()

            let event = try #require(events.first)
            #expect(events.count == 1)
            let image = try Self.saved(event.hash, in: rig)
            #expect(image.width == 96)
            #expect(image.height == 128)
            #expect(event.size == [24, 32])
            #expect(event.hotspot == [4.0 / 24, 6.0 / 32])
            // The drawing is there and the right way up: the red square is at the top left, 32 px a side.
            #expect(Self.alpha(image, x: 0, y: 0) == 255)
            #expect(Self.alpha(image, x: 31, y: 31) == 255)
            #expect(Self.alpha(image, x: 32, y: 0) == 0)
            #expect(Self.alpha(image, x: 0, y: 32) == 0)
            #expect(Self.alpha(image, x: 0, y: 127) == 0)
            #expect(Self.alpha(image, x: 95, y: 0) == 0)
        }
    }

    /// Over 128 pt the cursor is drawn at fewer than 4 pixels per point, so its image still fits the package's reader.
    @Test func bigCursorIsDrawnToFitTheReader() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try Rig(in: dir)
            let snapshot = try await MainActor.run {
                try unwrap(
                    CursorSnapshot(cursor: Self.cursor(size: NSSize(width: 200, height: 100), corner: 50, hotspot: NSPoint(x: 150, y: 20))),
                    "snapshot")
            }
            #expect(snapshot.image.width == 512)
            #expect(snapshot.image.height == 256)
            rig.cursor.set(snapshot)
            await rig.recorder.start(log: rig.log)
            let events = try await rig.finish()

            let event = try #require(events.first)
            #expect(event.size == [200, 100])
            #expect(event.hotspot == [0.75, 0.2])
            let image = try Self.saved(event.hash, in: rig)
            #expect(image.width == 512)
            #expect(image.height == 256)
            // 50 pt at 2.56 px per point: 128 px.
            #expect(Self.alpha(image, x: 127, y: 127) == 255)
            #expect(Self.alpha(image, x: 129, y: 0) == 0)
            #expect(Self.alpha(image, x: 0, y: 129) == 0)
            #expect(CursorSnapshot.scale(forPointSize: [24, 32]) == 4)
            #expect(CursorSnapshot.scale(forPointSize: [128, 40]) == 4)
            #expect(CursorSnapshot.scale(forPointSize: [100, 200]) == 2.56)
        }
    }

    /// A PNG over the reader's limit is not saved and logs no event.
    @Test func imageOverTheReadersLimitIsNotSaved() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try Rig(in: dir, maxImageBytes: 64)
            rig.cursor.set(try Self.snapshot(Self.red, fingerprint: 1))
            await rig.recorder.start(log: rig.log)
            let events = try await rig.finish()
            #expect(events.isEmpty)
            #expect(try rig.savedImages().isEmpty)
            #expect(rig.recorder.imagesWritten == 0)
        }
    }

    /// A `cursors` that is a file: nothing is written, no event, and the recorder goes on; once it is gone, the next
    /// shape is saved.
    @Test func cursorsThatIsAFileWritesNothing() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try Rig(in: dir)
            try Data("not a folder".utf8).write(to: rig.cursorsDirectory)
            let a = try Self.snapshot(Self.red, fingerprint: 1)
            let b = try Self.snapshot(Self.blue, fingerprint: 2)
            rig.cursor.set(a)
            await rig.recorder.start(log: rig.log)
            await rig.show(b)
            await rig.recorder.writesDone()
            try rig.log.flush()
            #expect(try EventLogReader.read(rig.log.url).events.isEmpty)
            #expect(try Data(contentsOf: rig.cursorsDirectory) == Data("not a folder".utf8))

            try FileManager.default.removeItem(at: rig.cursorsDirectory)
            await rig.show(a)
            let events = try await rig.finish()
            #expect(events.map(\.hash) == [CursorImageHash.hash(a)])
            #expect(try rig.savedImages() == [CursorImageHash.hash(a) + ".png"])
        }
    }

    /// A `cursors` that is a symlink is never followed: neither to write nor to find an image already there.
    @Test func cursorsThatIsASymlinkIsNotFollowed() async throws {
        try await withTemporaryDirectory { dir in
            let rig = try Rig(in: dir)
            let a = try Self.snapshot(Self.red, fingerprint: 1)
            let b = try Self.snapshot(Self.blue, fingerprint: 2)
            let elsewhere = dir.appendingPathComponent("elsewhere", isDirectory: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
            try Data("kept".utf8).write(to: elsewhere.appendingPathComponent(CursorImageHash.hash(a) + ".png"))
            try FileManager.default.createSymbolicLink(at: rig.cursorsDirectory, withDestinationURL: elsewhere)

            rig.cursor.set(a)
            await rig.recorder.start(log: rig.log)
            await rig.show(b)
            let events = try await rig.finish()
            #expect(events.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path) == [CursorImageHash.hash(a) + ".png"])
            #expect(rig.recorder.imagesWritten == 0)
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
