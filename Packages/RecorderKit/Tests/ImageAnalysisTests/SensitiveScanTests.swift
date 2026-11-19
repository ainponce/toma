// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing
@testable import ImageAnalysis

private let base = HostTime(nanoseconds: 5_000_000_000_000)

private func at(_ seconds: Double) -> HostTime {
    base.adding(seconds: seconds)
}

// MARK: - Frames with text

/// A line of text drawn black on white, as large as fits `rect` (fractions of the frame, from its top left).
struct ScreenText: Sendable {
    var text: String
    var rect: Rect
    var font = "Helvetica"
}

enum ScreenPainter {
    /// Paints the whole of `buffer` (BGRA) white with `texts` on it, and returns where the ink of each is, in fractions
    /// of the frame from its top left.
    @discardableResult
    static func paint(_ texts: [ScreenText], into buffer: CVPixelBuffer) -> [Rect] {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return [] }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let (w, h) = (Double(width), Double(height))
        return texts.map { item in
            // The size whose ascent and descent fill the rect's height, smaller if the line is too wide for it.
            func line(size: Double) -> (CTLine, CTFont) {
                let font = CTFontCreateWithName(item.font as CFString, size, nil)
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
                ]
                return (CTLineCreateWithAttributedString(NSAttributedString(string: item.text, attributes: attributes)), font)
            }
            let probe = CTFontCreateWithName(item.font as CFString, 100, nil)
            var size = item.rect.height * h / ((CTFontGetAscent(probe) + CTFontGetDescent(probe)) / 100)
            var (drawn, font) = line(size: size)
            let lineWidth = CTLineGetTypographicBounds(drawn, nil, nil, nil)
            if lineWidth > item.rect.width * w {
                size *= item.rect.width * w / lineWidth
                (drawn, font) = line(size: size)
            }
            // The baseline, from the bottom (Core Graphics' y), with the line's top at the rect's.
            let baseline = h - (item.rect.y * h + CTFontGetAscent(font))
            context.textPosition = CGPoint(x: item.rect.x * w, y: baseline)
            // Where the glyphs go, from the text position (which drawing moves to the line's end).
            let ink = CTLineGetImageBounds(drawn, context)
            CTLineDraw(drawn, context)
            return Rect(x: ink.minX / w, y: (h - ink.maxY) / h, width: ink.width / w, height: ink.height / h)
        }
    }

    /// A white BGRA frame `width` × `height` with `texts` on it, and where their ink is.
    static func frame(width: Int, height: Int, _ texts: [ScreenText]) throws -> (CVPixelBuffer, [Rect]) {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &created)
        let buffer = try unwrap(created, "a frame")
        return (buffer, paint(texts, into: buffer))
    }
}

/// A package with one take of display 1 (its frame `width` × `height` points at scale 1, and its Area if any): one
/// segment from `base`, `seconds` long at `fps`, each frame painted by `paint` (given its time from the start), or the
/// changing frames of `SampleFactory` without it.
func screenTake(
    in directory: URL, seconds: Double, width: Int = 1280, height: Int = 720, fps: Int = 30, area: Rect? = nil,
    paint: (@Sendable (_ seconds: Double, CVPixelBuffer) -> Void)? = nil
) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: directory)
    let source = TrackSource(
        name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: Double(width), height: Double(height)),
        pixelScale: 1, captureArea: area)
    var transform: (@Sendable (Int, CMSampleBuffer) -> CMSampleBuffer)?
    if let paint {
        transform = { index, sample in
            if let buffer = CMSampleBufferGetImageBuffer(sample) { paint(Double(index) / Double(fps), buffer) }
            return sample
        }
    }
    try await builder.addVideoTrack(
        id: "display-1", source: source,
        segments: [VideoSegmentSpec(start: base, seconds: seconds, framesPerSecond: fps, width: width, height: height, transform: transform)])
    return try builder.write()
}

// MARK: - A recognizer that does not look

/// Hands out what `respond` says for each call (counted from 0) and notes each call's crop and frame size.
final class FakeRecognizer: ScreenRecognizer {
    struct Call: Equatable, Sendable {
        var crop: Rect
        var width: Int
        var height: Int
    }

    private let calls = Mutex<[Call]>([])
    private let respond: @Sendable (Int) -> [FrameObservation]
    private let available: Bool

    init(available: Bool = true, respond: @escaping @Sendable (Int) -> [FrameObservation] = { _ in [] }) {
        self.available = available
        self.respond = respond
    }

    var isAvailable: Bool { available }

    func observe(_ frame: CVPixelBuffer, crop: Rect) throws -> [FrameObservation] {
        let call = Call(crop: crop, width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
        let number = calls.withLock { calls in
            calls.append(call)
            return calls.count - 1
        }
        return respond(number)
    }

    var made: [Call] { calls.withLock { $0 } }
}

/// What a progress callback was given, in order.
private final class Reports: Sendable {
    private let values = Mutex<[Double]>([])
    func add(_ value: Double) { values.withLock { $0.append(value) } }
    var all: [Double] { values.withLock { $0 } }
}

private func close(_ a: NormalizedRect, _ b: NormalizedRect, within e: Double = 1e-9) -> Bool {
    abs(a.x - b.x) <= e && abs(a.y - b.y) <= e && abs(a.width - b.width) <= e && abs(a.height - b.height) <= e
}

/// Whether `outer` holds `inner` (fractions), give or take `e`.
private func holds(_ outer: NormalizedRect, _ inner: Rect, within e: Double) -> Bool {
    outer.x <= inner.x + e && outer.y <= inner.y + e
        && outer.x + outer.width >= inner.x + inner.width - e && outer.y + outer.height >= inner.y + inner.height - e
}

private func scan(
    _ project: LoadedProject, recognizer: any ScreenRecognizer, progress: @escaping @Sendable (Double) -> Void = { _ in }
) async throws -> ScanResult {
    try await SensitiveScan.run(
        project: project, document: .legacy(for: project), recognizer: recognizer, segments: ["names"], progress: progress)
}

@Suite("SensitiveScan")
struct SensitiveScanTests {
    // MARK: - With Vision

    @Test(.enabled(if: VisionRecognizer.isAvailable))
    func findsTheTextAtItsPlace() async throws {
        let email = ScreenText(text: "ana.perez@gmail.com", rect: Rect(x: 0.2, y: 0.3, width: 0.3, height: 0.05))
        let (_, ink) = try ScreenPainter.frame(width: 1280, height: 720, [email])
        try await withTemporaryDirectory { directory in
            // Shown from 1.0 to 3.0 s, both included (a frame either side, so no rounding of its time leaves one out).
            let project = try await screenTake(in: directory, seconds: 4) { t, buffer in
                ScreenPainter.paint(t > 0.95 && t < 3.05 ? [email] : [], into: buffer)
            }
            let result = try await scan(project, recognizer: VisionRecognizer())
            #expect(result.findings.map(\.kind) == [.email])
            let finding = try #require(result.findings.first)
            #expect(finding.masked == "an•••@g•••.com")
            // Seen from the sample at 1.0 s to the one at 3.0 s, each 0.25 s more.
            #expect(finding.start == at(0.75))
            #expect(finding.end == at(3.25))
            #expect(finding.take == project.take.id)
            let first = try #require(finding.keys.first)
            #expect(first.t == at(1))
            #expect(holds(first.rect, ink[0], within: 0.002), "\(first.rect) holds \(ink[0])")
            // Not much more than the line around it.
            #expect(first.rect.width < 0.3 + 0.1 && first.rect.height < 0.05 + 0.05)
        }
    }

    @Test(.enabled(if: VisionRecognizer.isAvailable))
    func findsAKeyAndACard() async throws {
        try await withTemporaryDirectory { directory in
            let texts = [
                ScreenText(text: "sk_live_\u{34}eC39HqLyjWDarjtT1zdp7dc", rect: Rect(x: 0.1, y: 0.2, width: 0.6, height: 0.05), font: "Menlo"),
                ScreenText(text: "4242 4242 4242 4242", rect: Rect(x: 0.1, y: 0.5, width: 0.4, height: 0.05)),
            ]
            let project = try await screenTake(in: directory, seconds: 2) { _, buffer in
                ScreenPainter.paint(texts, into: buffer)
            }
            let result = try await scan(project, recognizer: VisionRecognizer())
            let found = Set(result.findings.map { "\($0.kind) \($0.masked)" })
            #expect(found == ["secret sk_live_•••", "card •••• 4242"])
            for finding in result.findings {
                #expect(finding.start == at(0) && finding.end == at(2))
            }
        }
    }

    @Test(.enabled(if: VisionRecognizer.isAvailable))
    func visionPlacesWhatItFindsInTheCrop() throws {
        let inside = ScreenText(text: "ana.perez@gmail.com", rect: Rect(x: 0.55, y: 0.6, width: 0.3, height: 0.05))
        let outside = ScreenText(text: "otro.correo@gmail.com", rect: Rect(x: 0.05, y: 0.1, width: 0.3, height: 0.05))
        let (frame, ink) = try ScreenPainter.frame(width: 1280, height: 720, [inside, outside])
        let crop = Rect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        let observations = try VisionRecognizer().observe(frame, crop: crop)
        #expect(observations.map(\.kind) == [.email])
        #expect(observations.map(\.text) == ["ana.perez@gmail.com"])
        let rect = try #require(observations.first?.rect)
        // The ink, in fractions of the crop.
        let expected = Rect(
            x: (ink[0].x - crop.x) / crop.width, y: (ink[0].y - crop.y) / crop.height,
            width: ink[0].width / crop.width, height: ink[0].height / crop.height)
        #expect(holds(rect, expected, within: 0.004), "\(rect) holds \(expected)")
        #expect(rect.width < expected.width + 0.06 && rect.height < expected.height + 0.06, "\(rect) close to \(expected)")
    }

    @Test(.enabled(if: VisionRecognizer.isAvailable))
    func theRectIsTheMatchNotTheLine() throws {
        // Accented letters before it: the match's range is of the line Vision read, whatever its encoding.
        let prefix = "Escribirle a José Núñez Ñandú: "
        let line = ScreenText(text: prefix + "ana.perez@gmail.com hoy", rect: Rect(x: 0.05, y: 0.4, width: 0.9, height: 0.05))
        let (frame, ink) = try ScreenPainter.frame(width: 1920, height: 1080, [line])
        let observations = try VisionRecognizer().observe(frame, crop: Rect(x: 0, y: 0, width: 1, height: 1))
        #expect(observations.map(\.text) == ["ana.perez@gmail.com"])
        let rect = try #require(observations.first?.rect)
        // The address is 19 of the line's 54 characters, after 31 of them: well right of the line's start, and short of
        // its end.
        let (start, end) = (rect.x, rect.x + rect.width)
        let lineStart = ink[0].x, lineWidth = ink[0].width
        #expect(start > lineStart + 0.45 * lineWidth && start < lineStart + 0.65 * lineWidth, "\(rect) in \(ink[0])")
        #expect(end > lineStart + 0.8 * lineWidth && end < lineStart + 0.985 * lineWidth, "\(rect) in \(ink[0])")
    }

    @Test(.enabled(if: VisionRecognizer.isAvailable))
    func aFullPageVisionReadsAsBlankIsReadAgain() throws {
        // Two of the bench's 4K pages where Vision's precise text, on macOS 26, reads no line at all (all 50 a few
        // pixels off): every address, phone and card on them is found all the same.
        for number in [22, 26] {
            let (frame, _) = try ScreenPainter.frame(width: 3840, height: 2160, PageCache.lines(of: number))
            let observations = try VisionRecognizer().observe(frame, crop: Rect(x: 0, y: 0, width: 1, height: 1))
            let kinds = Dictionary(grouping: observations, by: \.kind).mapValues(\.count)
            #expect(kinds == [.email: 10, .phone: 10, .card: 1], "page \(number)")
        }
    }

    @Test(.enabled(if: VisionRecognizer.isAvailable))
    func aScreenWithoutTextIsReadThreeTimesAndFindsNothing() throws {
        let (frame, _) = try ScreenPainter.frame(width: 1280, height: 720, [])
        #expect(try VisionRecognizer().observe(frame, crop: Rect(x: 0, y: 0, width: 1, height: 1)).isEmpty)
        // A crop of a few pixels is read too.
        #expect(try VisionRecognizer().observe(frame, crop: Rect(x: 0.5, y: 0.5, width: 2.0 / 1280, height: 2.0 / 720)).isEmpty)
    }

    // MARK: - With a recognizer that does not look

    @Test func aStillScreenIsRecognizedOnce() async throws {
        let text = ScreenText(text: "nothing to see", rect: Rect(x: 0.2, y: 0.4, width: 0.4, height: 0.06))
        let fake = FakeRecognizer { _ in
            [FrameObservation(kind: .email, text: "ana.perez@gmail.com", rect: NormalizedRect(x: 0.2, y: 0.4, width: 0.3, height: 0.05))]
        }
        try await withTemporaryDirectory { directory in
            let project = try await screenTake(in: directory, seconds: 10, width: 640, height: 360) { _, buffer in
                ScreenPainter.paint([text], into: buffer)
            }
            let result = try await scan(project, recognizer: fake)
            #expect(fake.made.count == 1)
            // What the first sample found holds for the other 39: one finding over the whole take.
            #expect(result.findings.count == 1)
            #expect(result.findings.first?.start == at(0))
            #expect(result.findings.first?.end == at(10))
            #expect(result.findings.first?.keys.map(\.t) == [at(0), at(9.75)])
        }
    }

    @Test func theAreaIsWhatIsScanned() async throws {
        let found = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)
        let fake = FakeRecognizer { _ in [FrameObservation(kind: .email, text: "ana.perez@gmail.com", rect: found)] }
        try await withTemporaryDirectory { directory in
            // The display is 1280 × 720 points; its Area, the middle of it.
            let project = try await screenTake(
                in: directory, seconds: 2, area: Rect(x: 320, y: 180, width: 640, height: 360))
            let result = try await scan(project, recognizer: fake)
            // `SampleFactory`'s frames change at each sample: all 8 are recognized, each in the whole frame and its Area.
            #expect(fake.made == Array(repeating: FakeRecognizer.Call(crop: Rect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), width: 1280, height: 720), count: 8))
            // The rects stay in fractions of the Area, as the recognizer gave them (grown 20 % of their height).
            let finding = try #require(result.findings.first)
            #expect(result.findings.count == 1)
            let grown = NormalizedRect(x: 0.08, y: 0.18, width: 0.34, height: 0.14)
            #expect(finding.keys.allSatisfy { close($0.rect, grown) }, "\(finding.keys)")
        }
    }

    @Test func cancellingStopsBetweenSamples() async throws {
        let gate = DispatchSemaphore(value: 0)
        let fake = FakeRecognizer { call in
            if call == 0 { gate.wait() }
            return []
        }
        try await withTemporaryDirectory { directory in
            let project = try await screenTake(in: directory, seconds: 2, width: 320, height: 180)
            let task = Task { try await scan(project, recognizer: fake) }
            #expect(await eventually { fake.made.count == 1 })
            task.cancel()
            gate.signal()
            await #expect(throws: CancellationError.self) { try await task.value }
            // The frames change at every sample: without the cancel, all 8 would have been recognized.
            #expect(fake.made.count == 1)
        }
    }

    @Test func progressGoesUpToOne() async throws {
        let reports = Reports()
        try await withTemporaryDirectory { directory in
            let project = try await screenTake(in: directory, seconds: 2, width: 320, height: 180)
            _ = try await scan(project, recognizer: FakeRecognizer(), progress: { reports.add($0) })
        }
        // One report per sample, the last one the whole.
        #expect(reports.all == (1...8).map { Double($0) / 8 })
    }

    @Test func aTakeWithoutSamplesIsDoneAtOnce() async throws {
        let reports = Reports()
        let fake = FakeRecognizer()
        try await withTemporaryDirectory { directory in
            let project = try await screenTake(in: directory, seconds: 2, width: 320, height: 180)
            var document = EditDocument.legacy(for: project)
            document.screens.initial = [:]
            let result = try await SensitiveScan.run(
                project: project, document: document, recognizer: fake, segments: [], progress: { reports.add($0) })
            #expect(result.findings.isEmpty)
        }
        #expect(fake.made.isEmpty)
        #expect(reports.all == [1])
    }

    @Test func theResultSaysWhatItWasMadeFrom() async throws {
        try await withTemporaryDirectory { directory in
            let project = try await screenTake(in: directory, seconds: 2, width: 320, height: 180)
            let document = EditDocument.legacy(for: project)
            let result = try await SensitiveScan.run(
                project: project, document: document, recognizer: FakeRecognizer(), segments: ["a", "b"], progress: { _ in })
            #expect(result.algorithm == "sensitiveScan-1")
            #expect(result.version == 1)
            #expect(result.take == project.take.id)
            #expect(result.segments == ["a", "b"])
            #expect(result.samples == SensitiveScan.fingerprint(project: project, document: document))
            // Another screen shown is another set of samples.
            var other = document
            other.screens.initial = [:]
            #expect(SensitiveScan.fingerprint(project: project, document: other) != result.samples)
        }
    }

    // MARK: - Segments

    @Test func anEmptySegmentIsNotAnError() async throws {
        try await withTemporaryDirectory { directory in
            let project = try await screenTakeWithSecondSegment(in: directory, file: .zeroBytes, endReason: .empty)
            // The output shows the frame before it there, and so does what is scanned.
            _ = try await scan(project, recognizer: FakeRecognizer())
        }
    }

    @Test func aSegmentThatCannotBeReadIsUnreadable() async throws {
        try await withTemporaryDirectory { directory in
            let project = try await screenTakeWithSecondSegment(in: directory, file: .garbage(), endReason: .stopped)
            await #expect(throws: SensitiveScanError.unreadable(file: "takes/take-001/display-1/seg-0002.mov")) {
                try await scan(project, recognizer: FakeRecognizer())
            }
        }
    }

    /// A take of display 1 with a segment of 1 s, and a second one from 1.5 to 2.5 s holding `file`.
    private func screenTakeWithSecondSegment(
        in directory: URL, file: SegmentFileFixture, endReason: SegmentEndReason
    ) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: directory)
        let source = TrackSource(
            name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 320, height: 180), pixelScale: 1)
        try await builder.addVideoTrack(
            id: "display-1", source: source,
            segments: [VideoSegmentSpec(start: base, seconds: 1, width: 320, height: 180, endReason: .paused)])
        try builder.addEmptySegment(
            track: "display-1", index: 2, start: at(1.5), end: at(2.5), endReason: endReason, file: file)
        return try builder.write()
    }

    // MARK: - Speed

    /// Design §13: at least real time with a 4K screen. 60 s of 3840 × 2160 at 60 fps whose text (50 lines of a dense
    /// screen, with addresses, phones and a card) changes every 2 s.
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1" && VisionRecognizer.isAvailable),
        .timeLimit(.minutes(15)))
    func sensitiveScanBench() async throws {
        let (width, height, fps, seconds) = (3840, 2160, 60, 60.0)
        let pages = PageCache(width: width, height: height)
        try await withTemporaryDirectory { directory in
            let made = ContinuousClock.now
            let project = try await screenTake(
                in: directory, seconds: seconds, width: width, height: height, fps: fps
            ) { t, buffer in
                pages.copy(page: Int(t / 2), into: buffer)
            }
            let fixture = ContinuousClock.now - made
            let counting = CountingRecognizer(VisionRecognizer())
            let start = ContinuousClock.now
            let result = try await scan(project, recognizer: counting)
            let elapsed = ContinuousClock.now - start
            let speed = seconds / (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            let kinds = Dictionary(grouping: result.findings, by: \.kind).mapValues(\.count)
            let seen = counting.seen
            print("sensitiveScanBench: \(elapsed) for \(seconds) s of 4K at \(fps) fps (\(String(format: "%.2f", speed))× real time); \(counting.count) of 240 samples recognized, seeing \(seen); findings \(kinds); fixture \(fixture)")
            #expect(speed >= 1)
            // Each page is recognized once, and on each its 10 addresses, its 10 phones and its card are found. (The
            // findings are fewer: a line's address on one page and on the next is one finding, in the same place.)
            #expect(counting.count == 30)
            #expect(seen[.email, default: 0] == 30 * 10)
            #expect(seen[.phone, default: 0] == 30 * 10)
            #expect(seen[.card, default: 0] == 30)
        }
    }
}

/// Counts the frames it hands to the recognizer it wraps.
private final class CountingRecognizer: ScreenRecognizer {
    private let inner: any ScreenRecognizer
    private let calls = Mutex(0)
    private let kinds = Mutex<[SensitiveKind: Int]>([:])

    init(_ inner: any ScreenRecognizer) {
        self.inner = inner
    }

    func observe(_ frame: CVPixelBuffer, crop: Rect) throws -> [FrameObservation] {
        let observations = try inner.observe(frame, crop: crop)
        calls.withLock { $0 += 1 }
        kinds.withLock { kinds in
            for observation in observations { kinds[observation.kind, default: 0] += 1 }
        }
        return observations
    }

    var count: Int { calls.withLock { $0 } }
    /// How many of each kind the frames handed in had, all together.
    var seen: [SensitiveKind: Int] { kinds.withLock { $0 } }
}

/// The bench's pages, drawn once each (Core Text is too slow to draw 3600 4K frames) and copied into every frame.
private final class PageCache: @unchecked Sendable {
    private let lock = NSLock()
    private let width: Int
    private let height: Int
    /// The page drawn last, and its number. Only touched with `lock` held.
    private var page: (number: Int, buffer: CVPixelBuffer)?

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Page `number`: 50 lines of 28 px (14 pt on a Retina screen) every 40 px, with an address on every fifth line, a
    /// phone on the line after it and a card on the 25th, all with the page's number in them.
    static func lines(of number: Int) -> [ScreenText] {
        (0..<50).map { i in
            let text: String
            switch i % 5 {
            case 0: text = "Pedido \(number)-\(i): enviar la factura a cliente\(number)x\(i)@example.com antes del viernes"
            case 1: text = "Llamar al +54 11 \(4000 + number * 10 + i) \(1000 + i * 7) para confirmar la entrega del pedido"
            default:
                text = i == 27
                    ? "Tarjeta de prueba 4242 4242 4242 4242, vence 12/\(30 + number % 10), página \(number)"
                    : "Línea \(i) de la página \(number): el informe trimestral muestra un aumento del \(i + number) por ciento"
            }
            return ScreenText(text: text, rect: Rect(x: 0.02, y: (40 + Double(i) * 40) / 2160, width: 0.9, height: 28 / 2160))
        }
    }

    func copy(page number: Int, into destination: CVPixelBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if page?.number != number, let (buffer, _) = try? ScreenPainter.frame(width: width, height: height, Self.lines(of: number)) {
            page = (number, buffer)
        }
        guard let source = page?.buffer else { return }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(destination) else { return }
        let (fromRow, toRow) = (CVPixelBufferGetBytesPerRow(source), CVPixelBufferGetBytesPerRow(destination))
        for y in 0..<height { (to + y * toRow).copyMemory(from: from + y * fromRow, byteCount: width * 4) }
    }
}
