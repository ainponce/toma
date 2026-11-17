// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Darwin
@testable import Export
import Foundation
import ImageIO
import Metal
import ProjectFormat
import RecorderKitTestSupport
import Render
import Synchronization
import Testing
import UniformTypeIdentifiers

// gifQuant-1 (1c design §7.2; plan decisions 17, 18 and 39): its palettes pinned, and the bench of the fixed corpus its
// constants were tuned on and frozen with, against ImageIO's GIF of the same frames. ImageIO's GIF encoder
// (`CGImageDestination`) is only the yardstick here: never in the product. Serialized like GIFExporterTests: two
// renderers evaluating a smoothed cursor at once trip TSan in CursorPath.

private func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

/// Runs `body` on a thread of its own: drawing decodes, which blocks in `copyNextSampleBuffer`, and many tests blocking
/// Swift's cooperative pool at once hang the run.
private func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result(catching: body)) }.start()
    }
}

/// SplitMix64: the same numbers on every run.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - The corpus

/// The display of the corpus: 1280 × 720 points of one pixel each, recorded at 30 fps.
private let corpusDisplay = TrackSource(
    name: "Corpus Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 1280, height: 720), pixelScale: 1)
private let corpusCameraID = "camera"
private let corpusCamera = TrackSource(name: "Corpus Camera", deviceUniqueID: "corpus-camera")
private let corpusWidth = 1280
private let corpusHeight = 720
private let corpusSeconds = 10.0
private let corpusFPS = 30

/// The fixed GIF corpus of 1c design §16.1 (plan decision 39): four takes of 10 s made here, in code, nothing downloaded.
private enum GIFCorpus: String, CaseIterable, Sendable, CustomStringConvertible {
    /// A tutorial with clicks and typing: a light window where the text appears line by line and a cursor that clicks,
    /// with Toma's look (the `aurora-1` wallpaper, padding, shadow, the cursor with its ripples) and a zoom while it types.
    case tutorial
    /// Scrolling in a browser: bands of text and pictures going up, Toma's look.
    case browserScroll
    /// The `aurora-1` wallpaper around a dark editor with the camera's bubble: a camera of soft noise.
    case wallpaperBubble
    /// The camera full screen: the project's layout Camera full screen (1c design §5.1) over a take with a lively camera
    /// (the screen under it is never seen). Until the render drew the camera layouts (Tasks 10 and 11), this take was the
    /// same camera recorded as the screen and filling the output; Task 13 re-ran the corpus with the layout.
    case cameraFull

    var description: String { rawValue }

    /// Writes the take into a package in `dir` and returns it with its edit.
    func make(in dir: URL) async throws -> (LoadedProject, EditDocument) {
        let builder = try TakeBuilder(in: dir, name: "Corpus \(rawValue)")
        // Always the same pixels: the software encoder, which VideoToolbox picks when the hardware one is busy, decodes to
        // others.
        builder.videoEncoder = .hardwareOnly
        let screen: @Sendable (Int, CMSampleBuffer) -> CMSampleBuffer
        switch self {
        case .tutorial:
            screen = { index, sample in
                paintedSample(pts: sample.presentationTimeStamp) { tutorialScreen($0, t: Double(index) / Double(corpusFPS)) }
            }
        case .browserScroll:
            let page = BrowserPage()
            screen = { index, sample in
                paintedSample(pts: sample.presentationTimeStamp) { browserScreen($0, page: page, t: Double(index) / Double(corpusFPS)) }
            }
        case .wallpaperBubble:
            let code = EditorCode()
            screen = { index, sample in
                paintedSample(pts: sample.presentationTimeStamp) { editorScreen($0, code: code, t: Double(index) / Double(corpusFPS)) }
            }
        case .cameraFull:
            // Under the camera, never drawn nor decoded (1c design §14.4).
            screen = { _, sample in sample }
        }
        func segment(_ paint: @escaping @Sendable (Int, CMSampleBuffer) -> CMSampleBuffer) -> [VideoSegmentSpec] {
            [VideoSegmentSpec(
                start: base, seconds: corpusSeconds, framesPerSecond: corpusFPS, width: corpusWidth, height: corpusHeight, transform: paint)]
        }
        try await builder.addVideoTrack(id: displayID, source: corpusDisplay, segments: segment(screen))
        if self == .wallpaperBubble || self == .cameraFull {
            let lively = self == .cameraFull
            try await builder.addVideoTrack(id: corpusCameraID, kind: .camera, source: corpusCamera, segments: segment { index, sample in
                cameraSample(index: index, pts: sample.presentationTimeStamp, lively: lively)
            })
        }
        try builder.addEvents(cursorEvents)
        let project = try builder.write()

        var document = EditDocument.legacy(for: project)
        switch self {
        case .tutorial:
            document = tomaLook(document)
            // The text is typed close up: in at the first click, out before the second.
            document.zoom.regions = [
                ZoomRegion(id: "z-00000001", take: takeID, start: at(1.0), end: at(7.6), origin: .user, depth: 2,
                           focus: .fixed(x: 0.42, y: 0.36), instant: false),
            ]
        case .browserScroll, .wallpaperBubble:
            document = tomaLook(document)
        case .cameraFull:
            document.style.padding = 0
            document.style.cornerRadius = 0
            document.style.shadow = 0
            document.cursor.show = false
            document.camera.show = true
            document.camera.layout = CameraLayout(kind: .cameraFull)
        }
        return (project, document)
    }

    /// The pointer: moves (sampled at 120 Hz) with an ease in and out, clicks at their place.
    private var cursorEvents: [InputEvent] {
        let path: [(t: Double, x: Double, y: Double, click: Bool)] = switch self {
        case .tutorial:
            [(0, 760, 470, false), (0.7, 430, 214, true), (8.0, 430, 214, false), (8.5, 1105, 647, true), (9.3, 930, 560, false)]
        case .browserScroll:
            [(0, 980, 420, false), (0.6, 1010, 440, false)]
        case .wallpaperBubble:
            [(0, 900, 300, false), (3.0, 650, 402, true), (9.0, 700, 420, false)]
        case .cameraFull:
            []
        }
        var events: [InputEvent] = []
        for (from, to) in zip(path, path.dropFirst()) {
            let steps = max(1, Int((to.t - from.t) * 120))
            for i in 0...steps {
                let s = Double(i) / Double(steps)
                let eased = s * s * (3 - 2 * s)
                events.append(InputEvent(
                    t: at(from.t + (to.t - from.t) * s),
                    kind: .cursor(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased)))
            }
            if to.click {
                events.append(InputEvent(t: at(to.t + 0.08), kind: .mouseDown(.left, x: to.x, y: to.y)))
                events.append(InputEvent(t: at(to.t + 0.18), kind: .mouseUp(.left, x: to.x, y: to.y)))
            }
        }
        return events
    }
}

/// Toma's look for a new project (`DefaultStyle.toma`, as `StyleCommands.applyDefaultStyle` puts it, with Toma's arrow:
/// the takes have no recorded cursor images), without its automatic zoom: each take says its own zoom.
private func tomaLook(_ document: EditDocument) -> EditDocument {
    var document = document
    let toma = DefaultStyle.toma
    document.style = toma.style
    document.style.screenSampling = .mipmapped
    document.style.geometryTransition = .spring
    document.cursor = toma.cursor
    document.cursor.style = .toma
    document.zoom.show = toma.zoomShow
    document.zoom.spring = toma.zoomSpring
    document.zoom.motionBlur = toma.zoomMotionBlur
    return document
}

/// A frame of the corpus display presented at `pts`: painted by `paint` with Core Graphics in sRGB, the origin at the top
/// left and y down, then given to `pixels` (its BGRA bytes and bytes per row), if any.
private func paintedSample(
    width: Int = corpusWidth, height: Int = corpusHeight, pts: CMTime, paint: (Painter) -> Void,
    pixels: ((UnsafeMutablePointer<UInt8>, Int) -> Void)? = nil
) -> CMSampleBuffer {
    var created: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &created)
    guard status == kCVReturnSuccess, let pixelBuffer = created else { preconditionFailure("corpus frame: \(status)") }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let address = CVPixelBufferGetBaseAddress(pixelBuffer)!
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let context = CGContext(
        data: address, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    paint(Painter(context: context))
    context.flush()
    pixels?(address.assumingMemoryBound(to: UInt8.self), bytesPerRow)
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    do {
        let format = try CMVideoFormatDescription(imageBuffer: pixelBuffer)
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        return try CMSampleBuffer(imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: timing)
    } catch {
        preconditionFailure("corpus frame: \(error)")
    }
}

/// Core Graphics with sRGB colours as `0xRRGGBB`, y down.
private struct Painter {
    let context: CGContext

    static func font(_ size: CGFloat, bold: Bool = false) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)!
    }

    static func mono(_ size: CGFloat) -> CTFont { CTFontCreateWithName("Menlo" as CFString, size, nil) }

    func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }

    func rect(_ rect: CGRect, _ hex: UInt32, radius: CGFloat = 0, alpha: CGFloat = 1) {
        context.setFillColor(color(hex, alpha))
        if radius > 0 {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        } else {
            context.fill(rect)
        }
    }

    func ellipse(_ rect: CGRect, _ hex: UInt32, alpha: CGFloat = 1) {
        context.setFillColor(color(hex, alpha))
        context.fillEllipse(in: rect)
    }

    /// A linear gradient from `from` to `to` (each a colour and its point) clipped to `rect`, or to `clip` if given.
    func gradient(_ rect: CGRect, _ from: (UInt32, CGPoint), _ to: (UInt32, CGPoint), clip: CGPath? = nil) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let gradient = CGGradient(colorsSpace: space, colors: [color(from.0), color(to.0)] as CFArray, locations: [0, 1])!
        context.saveGState()
        if let clip { context.addPath(clip); context.clip() } else { context.clip(to: rect) }
        context.drawLinearGradient(gradient, start: from.1, end: to.1, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    /// A radial glow of `hex` from `alpha` at `center` to nothing at `radius`.
    func glow(_ center: CGPoint, radius: CGFloat, _ hex: UInt32, alpha: CGFloat) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let gradient = CGGradient(colorsSpace: space, colors: [color(hex, alpha), color(hex, 0)] as CFArray, locations: [0, 1])!
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    /// Draws `string` with its baseline at `y` from `x` and returns its width.
    @discardableResult
    func text(_ string: String, x: CGFloat, y: CGFloat, font: CTFont, _ hex: UInt32, alpha: CGFloat = 1) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(hex, alpha),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    static func width(_ string: String, font: CTFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

private func smoothstep(_ x: Double) -> Double {
    let s = min(1, max(0, x))
    return s * s * (3 - 2 * s)
}

/// The tutorial: a notes window on a light desktop; seven lines appear one after another, typed fast; the Publish button
/// is pressed at 8.6 s and a note says so.
private func tutorialScreen(_ p: Painter, t: Double) {
    p.gradient(CGRect(x: 0, y: 0, width: 1280, height: 720), (0xDCE5EE, CGPoint(x: 0, y: 0)), (0xA9BED3, CGPoint(x: 0, y: 720)))
    p.rect(CGRect(x: 0, y: 0, width: 1280, height: 24), 0xEFEFEF)
    var x: CGFloat = 16
    for (i, item) in ["Notes", "File", "Edit", "Format", "View", "Window", "Help"].enumerated() {
        x += p.text(item, x: x, y: 17, font: Painter.font(13, bold: i == 0), 0x1D1D1F) + 20
    }
    p.text("Mon 10:41", x: 1190, y: 17, font: Painter.font(13), 0x1D1D1F)

    let window = CGRect(x: 90, y: 60, width: 1100, height: 620)
    p.context.saveGState()
    p.context.setShadow(offset: CGSize(width: 0, height: 12), blur: 34, color: p.color(0x000000, 0.35))
    p.rect(window, 0xFFFFFF, radius: 10)
    p.context.restoreGState()
    p.context.saveGState()
    p.context.addPath(CGPath(roundedRect: window, cornerWidth: 10, cornerHeight: 10, transform: nil))
    p.context.clip()
    p.rect(CGRect(x: 90, y: 60, width: 1100, height: 52), 0xECECEC)
    for (i, light) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        p.ellipse(CGRect(x: 108 + CGFloat(i) * 20, y: 80, width: 12, height: 12), UInt32(light))
    }
    p.text("Getting started", x: 590, y: 91, font: Painter.font(13, bold: true), 0x4D4D4D)
    p.rect(CGRect(x: 90, y: 112, width: 240, height: 568), 0xF4F4F6)
    p.rect(CGRect(x: 100, y: 124, width: 220, height: 28), 0xD8D8DE, radius: 6)
    for (i, item) in ["All Notes", "Recipes", "Work", "Travel", "Ideas", "Archive"].enumerated() {
        p.text(item, x: 116, y: 143 + CGFloat(i) * 34, font: Painter.font(14), i == 0 ? 0x1D1D1F : 0x55555A)
    }
    p.rect(CGRect(x: 330, y: 112, width: 1, height: 568), 0xDDDDDD)
    p.rect(CGRect(x: 90, y: 112, width: 1100, height: 1), 0xD5D5D5)
    p.text("Release checklist", x: 372, y: 166, font: Painter.font(26, bold: true), 0x1D1D1F)

    let lines = [
        "1. Record the screen with the camera on.",
        "2. Cut the pauses and the false starts.",
        "3. Zoom where the clicks are, then let it breathe.",
        "4. Pick a background and a little padding.",
        "5. Export a GIF at 800 px and 15 fps.",
        "6. Paste it in the issue and wait for questions.",
        "7. Answer them with another GIF.",
    ]
    let font = Painter.font(17)
    var caret: (x: CGFloat, y: CGFloat)?
    var typing = false
    for (k, line) in lines.enumerated() {
        let start = 1.0 + 0.95 * Double(k)
        guard t >= start else { break }
        let shown = min(line.count, Int((t - start) * 38))
        let text = String(line.prefix(shown))
        let y = 214 + CGFloat(k) * 34
        let width = p.text(text, x: 372, y: y, font: font, 0x333333)
        caret = (372 + width + 1, y)
        typing = shown < line.count
    }
    if let caret, typing || Int(t * 2) % 2 == 0 {
        p.rect(CGRect(x: caret.x, y: caret.y - 17, width: 2, height: 22), 0x1D1D1F)
    }
    let pressed = (8.6..<8.78).contains(t)
    p.rect(CGRect(x: 1050, y: 630, width: 112, height: 34), pressed ? 0x005FCC : 0x007AFF, radius: 8)
    p.text("Publish", x: 1080, y: 652, font: Painter.font(14, bold: true), 0xFFFFFF)
    if t >= 8.8 {
        let alpha = CGFloat(smoothstep((t - 8.8) / 0.25))
        p.rect(CGRect(x: 620, y: 600, width: 180, height: 40), 0x2C2C2E, radius: 20, alpha: alpha)
        p.text("Published", x: 676, y: 625, font: Painter.font(15, bold: true), 0xFFFFFF, alpha: alpha)
    }
    p.context.restoreGState()
}

/// What a browser shows of a long article: its blocks at their place on the page.
private struct BrowserPage: Sendable {
    enum Block: Sendable {
        case title(String), byline(String), heading(String), line(String, link: Bool), figure(seed: UInt64), caption(String)
    }

    /// Each block and the page's y of its top.
    let blocks: [(block: Block, y: Double)]

    init() {
        let words = """
            the a of to and in that it with as for on was is at by this be from or have an they which one you were all we \
            her she there would their will when who him been has more if no out so said what up its about into than them can \
            only other new some could time these two may then do first any my now such like our over man me even most made \
            after also did many before must through back years where much your way well down should because each just those \
            people how too little state good very make world still own see men work long get here between both life being \
            under never day same another know while last might us great old year off come since against go came right used \
            take three screen frame colour palette camera window record share export shipping quiet notes
            """.split(separator: " ").map(String.init)
        var random = SplitMix64(seed: 2026)
        func sentence(_ count: Int) -> String {
            (0..<count).map { _ in words[Int(random.next() % UInt64(words.count))] }.joined(separator: " ")
        }
        var blocks: [(Block, Double)] = [
            (.title("The quiet art of shipping small things"), 120), (.byline("Field Notes · 7 min read · November 2026"), 170),
        ]
        var y = 210.0
        for paragraph in 0..<18 {
            if paragraph % 4 == 3 {
                blocks.append((.heading(sentence(4).capitalized), y + 8))
                y += 52
            }
            let lines = 4 + Int(random.next() % 4)
            for k in 0..<lines {
                let link = k == 1 && paragraph % 3 == 0
                blocks.append((.line(sentence(k == lines - 1 ? 7 : 13), link: link), y))
                y += 27
            }
            y += 20
            if paragraph % 3 == 1 {
                blocks.append((.figure(seed: UInt64(paragraph)), y))
                y += 300
                blocks.append((.caption("Figure \(paragraph / 3 + 1). " + sentence(8)), y + 4))
                y += 44
            }
        }
        self.blocks = blocks
    }

    /// How far the page is scrolled at `t`: still, a long scroll, a pause to read, a faster one, still.
    static func offset(at t: Double) -> Double {
        func speed(_ t: Double) -> Double {
            let first = smoothstep((t - 0.8) / 0.4) * (1 - smoothstep((t - 3.6) / 0.6))
            let second = smoothstep((t - 5.2) / 0.4) * (1 - smoothstep((t - 8.4) / 0.6))
            return 260 * first + 340 * second
        }
        let step = 1.0 / 600
        return stride(from: 0, to: t, by: step).reduce(0) { $0 + speed($1) * step }
    }
}

/// The browser: its tab and toolbar over the article, scrolled by `BrowserPage.offset`, with the scroll bar while it moves.
private func browserScreen(_ p: Painter, page: BrowserPage, t: Double) {
    let scroll = BrowserPage.offset(at: t)
    let moving = abs(BrowserPage.offset(at: t + 0.05) - scroll) > 0.5
    p.rect(CGRect(x: 0, y: 0, width: 1280, height: 720), 0xFFFFFF)
    p.context.saveGState()
    p.context.clip(to: CGRect(x: 0, y: 136, width: 1280, height: 584))
    for (block, top) in page.blocks {
        let y = top - scroll + 136
        // A picture is 290 high: drawn while any of it shows.
        guard y > -300, y < 760 else { continue }
        switch block {
        case .title(let text): p.text(text, x: 260, y: y, font: Painter.font(34, bold: true), 0x202124)
        case .byline(let text): p.text(text, x: 260, y: y, font: Painter.font(13), 0x5F6368)
        case .heading(let text): p.text(text, x: 260, y: y, font: Painter.font(22, bold: true), 0x202124)
        case .line(let text, let link): p.text(text, x: 260, y: y, font: Painter.font(16), link ? 0x1A73E8 : 0x3C4043)
        case .caption(let text): p.text(text, x: 260, y: y + 14, font: Painter.font(13), 0x5F6368)
        case .figure(let seed): figure(p, CGRect(x: 260, y: y, width: 760, height: 290), seed: seed)
        }
    }
    p.context.restoreGState()
    // The page's header stays where it is.
    p.rect(CGRect(x: 0, y: 85, width: 1280, height: 51), 0xFFFFFF)
    p.rect(CGRect(x: 0, y: 135, width: 1280, height: 1), 0xECECEC)
    p.text("Field Notes", x: 260, y: 117, font: Painter.font(18, bold: true), 0x202124)
    for (i, item) in ["Essays", "Projects", "About"].enumerated() {
        p.text(item, x: 820 + CGFloat(i) * 80, y: 116, font: Painter.font(14), 0x5F6368)
    }
    if moving {
        let thumb = 136 + scroll / 2600 * 584
        p.rect(CGRect(x: 1268, y: thumb, width: 8, height: 120), 0xC1C1C1, radius: 4)
    }
    // The browser's tab and toolbar.
    p.rect(CGRect(x: 0, y: 0, width: 1280, height: 38), 0xDFE1E5)
    p.rect(CGRect(x: 8, y: 6, width: 250, height: 36), 0xFFFFFF, radius: 8)
    p.ellipse(CGRect(x: 20, y: 16, width: 14, height: 14), 0xE8710A)
    p.text("The quiet art of shipping – Field…", x: 42, y: 28, font: Painter.font(12), 0x202124)
    p.rect(CGRect(x: 0, y: 38, width: 1280, height: 46), 0xFFFFFF)
    for i in 0..<3 { p.ellipse(CGRect(x: 18 + CGFloat(i) * 32, y: 50, width: 22, height: 22), 0xE8EAED) }
    p.rect(CGRect(x: 120, y: 46, width: 1040, height: 30), 0xF1F3F4, radius: 15)
    p.text("fieldnotes.example/2026/the-quiet-art-of-shipping", x: 140, y: 66, font: Painter.font(13), 0x202124)
    p.rect(CGRect(x: 0, y: 84, width: 1280, height: 1), 0xDADCE0)
}

/// A picture in the article: a sky, a sun and hills going to half their colour, all gradients.
private func figure(_ p: Painter, _ frame: CGRect, seed: UInt64) {
    var random = SplitMix64(seed: seed)
    let skies: [(UInt32, UInt32)] = [(0x87B5E5, 0xF2D8B0), (0x3D5A80, 0xEE9B6D), (0xA8D5E2, 0xF9F3E6)]
    let sky = skies[Int(random.next() % 3)]
    let clip = CGPath(roundedRect: frame, cornerWidth: 8, cornerHeight: 8, transform: nil)
    p.gradient(frame, (sky.0, CGPoint(x: frame.minX, y: frame.minY)), (sky.1, CGPoint(x: frame.minX, y: frame.maxY)), clip: clip)
    p.context.saveGState()
    p.context.addPath(clip)
    p.context.clip()
    let sun = CGPoint(x: frame.minX + 120 + CGFloat(random.next() % 500), y: frame.minY + 70)
    p.glow(sun, radius: 140, 0xFFF4D0, alpha: 0.9)
    for (i, hill) in [0x6E9A55, 0x4E7A3C, 0x355E2B].enumerated() {
        let width = 520 + CGFloat(random.next() % 300)
        let x = frame.minX - 120 + CGFloat(random.next() % 600)
        let top = frame.minY + 150 + CGFloat(i) * 40
        p.gradient(
            frame, (UInt32(hill), CGPoint(x: 0, y: top)), (UInt32(hill) >> 1 & 0x7F7F7F, CGPoint(x: 0, y: frame.maxY)),
            clip: CGPath(ellipseIn: CGRect(x: x, y: top, width: width, height: 360), transform: nil))
    }
    p.context.restoreGState()
}

/// The code of the dark editor, a line per entry, each a run of tokens with their colours.
private struct EditorCode: Sendable {
    let lines: [[(String, UInt32)]]

    init() {
        let source = """
            // SPDX-License-Identifier: GPL-3.0-or-later
            import Foundation

            /// The frames of a range, each at its time.
            struct FrameClock: Sendable {
                let start: Int64
                let framesPerSecond: Int

                func time(of frame: Int) -> Int64 {
                    start + Int64(frame) * 1_000_000_000 / Int64(framesPerSecond)
                }
            }

            enum Delay {
                static func hundredths(frame: Int, fps: Int) -> Int {
                    let next = ((frame + 1) * 100 + fps / 2) / fps
                    let this = (frame * 100 + fps / 2) / fps
                    return next - this
                }
            }

            let clock = FrameClock(start: 0, framesPerSecond: 15)
            for frame in 0..<150 {
                print("frame", frame, clock.time(of: frame), Delay.hundredths(frame: frame, fps: 15))
            }
            """
        let keywords: Set<String> = ["import", "struct", "let", "func", "return", "enum", "static", "for", "in", "var"]
        lines = source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> [(String, UInt32)] in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return [(String(line), 0x6A9955)] }
            var tokens: [(String, UInt32)] = []
            var word = ""
            var inString = false
            func flush() {
                guard !word.isEmpty else { return }
                let color: UInt32 = if inString { 0xCE9178 } else if keywords.contains(word) { 0x569CD6 }
                    else if word.first?.isUppercase == true { 0x4EC9B0 } else if word.first?.isNumber == true { 0xB5CEA8 }
                    else { 0x9CDCFE }
                tokens.append((word, color))
                word = ""
            }
            for character in line {
                if character == "\"" {
                    if inString {
                        word.append(character)
                        flush()
                        inString = false
                    } else {
                        flush()
                        inString = true
                        word.append(character)
                    }
                } else if inString || character.isLetter || character.isNumber || character == "_" {
                    word.append(character)
                } else {
                    flush()
                    tokens.append((String(character), 0xD4D4D4))
                }
            }
            flush()
            return tokens
        }
    }
}

/// A dark code editor; a line is typed in from 2 s to 7 s.
private func editorScreen(_ p: Painter, code: EditorCode, t: Double) {
    p.rect(CGRect(x: 0, y: 0, width: 1280, height: 720), 0x1E1E1E)
    p.rect(CGRect(x: 0, y: 0, width: 48, height: 720), 0x333333)
    for i in 0..<5 { p.rect(CGRect(x: 14, y: 50 + CGFloat(i) * 48, width: 20, height: 20), i == 0 ? 0xD7D7D7 : 0x858585, radius: 3) }
    p.rect(CGRect(x: 48, y: 0, width: 252, height: 720), 0x252526)
    p.text("EXPLORER", x: 68, y: 24, font: Painter.font(11, bold: true), 0xBBBBBB)
    for (i, file) in ["Package.swift", "Sources", "  FrameClock.swift", "  main.swift", "Tests", "README.md"].enumerated() {
        if i == 3 { p.rect(CGRect(x: 48, y: 44 + CGFloat(i) * 24, width: 252, height: 24), 0x37373D) }
        p.text(file, x: 68, y: 61 + CGFloat(i) * 24, font: Painter.font(13), 0xCCCCCC)
    }
    p.rect(CGRect(x: 300, y: 0, width: 980, height: 35), 0x2D2D2D)
    p.rect(CGRect(x: 300, y: 0, width: 150, height: 35), 0x1E1E1E)
    p.text("main.swift", x: 330, y: 22, font: Painter.font(13), 0xFFFFFF)
    let mono = Painter.mono(14)
    let advance = Painter.width("M", font: mono)
    let typed = "let total = (0..<150).reduce(0) { $0 + Delay.hundredths(frame: $1, fps: 15) }"
    let shown = Int(min(1, max(0, (t - 2) / 5)) * Double(typed.count))
    for (n, tokens) in code.lines.enumerated() {
        let y = 62 + CGFloat(n) * 21
        p.text("\(n + 1)", x: 318, y: y, font: mono, 0x858585)
        var x: CGFloat = 370
        for (token, color) in tokens {
            p.text(token, x: x, y: y, font: mono, color)
            x += advance * CGFloat(token.count)
        }
    }
    let line = CGFloat(code.lines.count + 1)
    let y = 62 + line * 21
    p.rect(CGRect(x: 300, y: y - 16, width: 980, height: 21), 0x2A2D2E)
    p.text("\(code.lines.count + 2)", x: 318, y: y, font: mono, 0xC6C6C6)
    p.text(String(typed.prefix(shown)), x: 370, y: y, font: mono, 0xD4D4D4)
    if shown < typed.count || Int(t * 2) % 2 == 0 {
        p.rect(CGRect(x: 370 + advance * CGFloat(shown), y: y - 15, width: 2, height: 19), 0xAEAFAD)
    }
    p.rect(CGRect(x: 0, y: 698, width: 1280, height: 22), 0x007ACC)
    p.text("main    0 errors    0 warnings", x: 60, y: 713, font: Painter.font(12), 0xFFFFFF)
    p.text("Ln \(code.lines.count + 2), Col \(shown + 1)   Spaces: 4   UTF-8   Swift", x: 980, y: 713, font: Painter.font(12), 0xFFFFFF)
}

/// A camera's frame: a person in front of a warm wall with a lamp and a shelf, soft sensor noise on every pixel (seeded
/// by the frame). `lively`: the head moves more and a hand waves from 3.5 s to 6 s (the camera full screen); otherwise
/// a person who mostly listens (the bubble).
private func cameraSample(index: Int, pts: CMTime, lively: Bool) -> CMSampleBuffer {
    let t = Double(index) / Double(corpusFPS)
    return paintedSample(pts: pts, paint: { p in
        p.gradient(CGRect(x: 0, y: 0, width: 1280, height: 720), (0x8C8174, CGPoint(x: 0, y: 0)), (0x5A5048, CGPoint(x: 1280, y: 720)))
        p.rect(CGRect(x: 40, y: 80, width: 300, height: 520), 0x3E342C)
        for i in 0..<14 {
            let colors: [UInt32] = [0x9C3D2E, 0x2E5C8A, 0xC9A227, 0x4F7942, 0x7A4E8C]
            let spine = CGRect(x: 52 + CGFloat(i % 7) * 40, y: 100 + CGFloat(i / 7) * 250, width: 30, height: 210)
            p.rect(spine, colors[i % colors.count], radius: 3)
        }
        p.glow(CGPoint(x: 1060, y: 140), radius: 420, 0xFFD9A0, alpha: 0.45)
        let sway = lively ? 34 * sin(2 * .pi * 0.35 * t) : 10 * sin(2 * .pi * 0.25 * t)
        let nod = lively ? 10 * sin(2 * .pi * 0.9 * t) : 4 * sin(2 * .pi * 0.4 * t)
        let head = CGPoint(x: 640 + sway, y: 320 + nod)
        p.gradient(
            CGRect(x: 0, y: 0, width: 1280, height: 720), (0x35506E, CGPoint(x: 0, y: 520)), (0x1F3247, CGPoint(x: 0, y: 720)),
            clip: CGPath(ellipseIn: CGRect(x: head.x - 330, y: 520, width: 660, height: 420), transform: nil))
        p.rect(CGRect(x: head.x - 55, y: head.y + 140, width: 110, height: 110), 0xC48A6C)
        p.gradient(
            CGRect(x: 0, y: 0, width: 1280, height: 720), (0xE7BA9C, CGPoint(x: head.x - 60, y: head.y - 80)),
            (0xA9705A, CGPoint(x: head.x + 120, y: head.y + 170)),
            clip: CGPath(ellipseIn: CGRect(x: head.x - 140, y: head.y - 180, width: 280, height: 360), transform: nil))
        p.ellipse(CGRect(x: head.x - 150, y: head.y - 205, width: 300, height: 170), 0x3A2A20)
        let blink = Int(t * 30) % 110 < 4
        for side in [-1.0, 1.0] {
            p.ellipse(CGRect(x: head.x + side * 52 - 16, y: head.y - 10, width: 32, height: blink ? 3 : 14), 0x2A1E18)
        }
        p.ellipse(CGRect(x: head.x - 40, y: head.y + 80, width: 80, height: 18), 0x8E4F44)
        if lively, (3.5..<6).contains(t) {
            let raise = smoothstep((t - 3.5) / 0.6) * (1 - smoothstep((t - 5.4) / 0.6))
            let wave = 40 * sin(2 * .pi * 2.2 * t)
            let hand = CGPoint(x: 980 + wave, y: 760 - 380 * raise)
            p.gradient(
                CGRect(x: 0, y: 0, width: 1280, height: 720), (0xE2B293, CGPoint(x: hand.x, y: hand.y - 80)),
                (0xB07A60, CGPoint(x: hand.x, y: hand.y + 120)),
                clip: CGPath(ellipseIn: CGRect(x: hand.x - 70, y: hand.y - 90, width: 140, height: 200), transform: nil))
            p.rect(CGRect(x: hand.x - 45, y: hand.y + 90, width: 90, height: 400), 0x2B4560)
        }
    }, pixels: { bytes, bytesPerRow in
        var random = SplitMix64(seed: UInt64(index + 1) &* 0x2545_F491_4F6C_DD1D)
        for y in 0..<corpusHeight {
            let row = bytes + y * bytesPerRow
            for x in 0..<corpusWidth {
                let r = random.next()
                for c in 0..<3 {
                    // Triangular noise of σ ≈ 3.2 levels.
                    let noise = (Int(r >> (16 * c) & 0xFF) + Int(r >> (16 * c + 8) & 0xFF) - 255) / 32
                    let value = Int(row[x * 4 + c]) + noise
                    row[x * 4 + c] = UInt8(min(255, max(0, value)))
                }
            }
        }
    })
}

// MARK: - Measuring

/// The frames of `range` at the GIF's size as the export draws them (`FrameRenderer.renderBytes` at each frame's time,
/// the shutter of a frame of the project), BGRA rows without padding.
private func renderedFrames(_ project: LoadedProject, _ document: EditDocument, settings: GIFSettings) async throws -> [[UInt8]] {
    try await offThePool {
        let size = settings.outputSize(aspect: document.aspect)
        let renderer = try FrameRenderer(project: project, document: document, outputSize: size, frameRate: document.frameRate)
        return try (0..<settings.range.frameCount(fps: settings.fps)).map { n in
            try renderer.renderBytes(at: Double(settings.range.frameTime(n, fps: settings.fps)) / 1e9)
        }
    }
}

/// OKLab of every 8-bit sRGB colour (`OKLab.fromSRGB`), three `Float`s at `(r << 16 | g << 8 | b) × 3`: to measure the
/// error of millions of pixels.
private final class OKLabTable: Sendable {
    static let shared = OKLabTable()
    let values: [Float]

    private init() {
        var values = [Float](repeating: 0, count: (1 << 24) * 3)
        values.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: 256) { r in
                for g in 0..<256 {
                    for b in 0..<256 {
                        let lab = OKLab.fromSRGB(SIMD3(Float(r), Float(g), Float(b)) / 255)
                        let i = (r << 16 | g << 8 | b) * 3
                        out[i] = lab.x
                        out[i + 1] = lab.y
                        out[i + 2] = lab.z
                    }
                }
            }
        }
        self.values = values
    }

    func lab(_ color: SIMD3<UInt8>) -> SIMD3<Float> {
        let i = (Int(color.x) << 16 | Int(color.y) << 8 | Int(color.z)) * 3
        return SIMD3(values[i], values[i + 1], values[i + 2])
    }
}

/// The sum over the pixels of the distance in OKLab between a rendered frame (BGRA) and what a GIF shows of it (`shown`,
/// RGB), and how many are farther than `largeError`.
private func distances(_ frame: [UInt8], _ shown: [SIMD3<UInt8>], largeError: Float = .infinity) -> (sum: Double, large: Int) {
    let table = OKLabTable.shared
    var sum = 0.0
    var large = 0
    table.values.withUnsafeBufferPointer { lab in
        frame.withUnsafeBufferPointer { frame in
            shown.withUnsafeBufferPointer { shown in
                for i in 0..<shown.count {
                    let a = (Int(frame[i * 4 + 2]) << 16 | Int(frame[i * 4 + 1]) << 8 | Int(frame[i * 4])) * 3
                    let c = shown[i]
                    let b = (Int(c.x) << 16 | Int(c.y) << 8 | Int(c.z)) * 3
                    let dl = lab[a] - lab[b], da = lab[a + 1] - lab[b + 1], db = lab[a + 2] - lab[b + 2]
                    let distance = (dl * dl + da * da + db * db).squareRoot()
                    sum += Double(distance)
                    if distance > largeError { large += 1 }
                }
            }
        }
    }
    return (sum, large)
}

/// What a viewer shows at each of the `count` frames of a GIF at `fps` (`GIFTestDecoder.frames`, each image for as many
/// frames as its delay covers), or `nil` if it does not read as one.
private func shownFrames(of gif: Data, count: Int, fps: Int) -> [[SIMD3<UInt8>]]? {
    let images = GIFTestDecoder.frames(gif)
    guard !images.isEmpty else { return nil }
    if images.count == count { return images.map(\.canvas) }
    let delays = GIFDelays.delays(frameCount: count, fps: fps)
    var shown: [[SIMD3<UInt8>]] = []
    for (canvas, delay) in images {
        var covered = 0
        while covered < delay, shown.count < count {
            covered += delays[shown.count]
            shown.append(canvas)
        }
    }
    return shown.count == count ? shown : nil
}

/// The mean distance in OKLab, over every pixel of every frame, between the rendered frames and what `gif` shows of them.
private func meanError(of gif: Data, frames: [[UInt8]], fps: Int) throws -> Double {
    let shown = try #require(shownFrames(of: gif, count: frames.count, fps: fps), "the GIF does not decode to \(frames.count) frames")
    let sum = zip(frames, shown).reduce(0.0) { $0 + distances($1.0, $1.1).sum }
    return sum / Double(frames.count * shown[0].count)
}

/// The bytes the process's malloc zones hold now (`malloc_zone_statistics`): what is allocated, whatever the pages freed
/// earlier that the allocator keeps (the footprint, which counts those, cannot tell what a later allocation reuses).
private func heapInUse() -> Int {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)
    return Int(statistics.size_in_use)
}

/// What `body` returns, and the most `heapInUse()` grew over its value before while it ran, sampled every millisecond.
private func peakHeapGrowth<T>(during body: () async throws -> T) async throws -> (T, Int) {
    let before = heapInUse()
    let largest = Mutex(before)
    let running = Atomic(true)
    let sampler = Thread {
        while running.load(ordering: .relaxed) {
            let now = heapInUse()
            largest.withLock { $0 = max($0, now) }
            usleep(1000)
        }
    }
    sampler.start()
    defer { running.store(false, ordering: .relaxed) }
    let value = try await body()
    let now = heapInUse()
    return (value, largest.withLock { max($0, now) } - before)
}

/// A rendered frame as a `CGImage` of its own copy of the bytes (sRGB, BGRA).
private func image(of frame: [UInt8], size: SIMD2<Int>) -> CGImage {
    let provider = CGDataProvider(data: Data(frame) as CFData)!
    return CGImage(
        width: size.x, height: size.y, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size.x * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

/// How ImageIO's GIF encoder used memory, in bytes allocated (`heapInUse`) over what was before: once every frame was
/// added (each from its own copy, released at once: what is left is what the destination keeps), the most while
/// `CGImageDestinationFinalize` ran, and what was left once the destination was gone.
private struct ImageIOMemory: Sendable {
    var added: Int
    var finalizing: Int
    var released: Int
}

/// ImageIO's GIF of the frames, the yardstick (1c design §4.3 and §15), with the same delays and loop as ours, and how
/// it used memory.
private func imageIOGIF(_ frames: [[UInt8]], size: SIMD2<Int>, fps: Int) throws -> (gif: Data, memory: ImageIOMemory) {
    let data = NSMutableData()
    let before = heapInUse()
    var added = 0
    let largest = Mutex(0)
    let finalizing = Atomic(true)
    let finished: Bool = try autoreleasepool {
        let destination = try #require(
            CGImageDestinationCreateWithData(data as CFMutableData, UTType.gif.identifier as CFString, frames.count, nil))
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for (frame, delay) in zip(frames, GIFDelays.delays(frameCount: frames.count, fps: fps)) {
            autoreleasepool {
                CGImageDestinationAddImage(destination, image(of: frame, size: size), [
                    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: Double(delay) / 100],
                ] as CFDictionary)
            }
        }
        added = heapInUse() - before
        // Sampled every millisecond while it finalizes.
        let sampler = Thread {
            while finalizing.load(ordering: .relaxed) {
                let now = heapInUse()
                largest.withLock { $0 = max($0, now) }
                usleep(1000)
            }
        }
        sampler.start()
        defer { finalizing.store(false, ordering: .relaxed) }
        return CGImageDestinationFinalize(destination)
    }
    try #require(finished)
    usleep(5000)
    let memory = ImageIOMemory(
        added: added, finalizing: max(added, largest.withLock { $0 } - before), released: heapInUse() - before - data.length)
    return (data as Data, memory)
}

/// Writes, for the owner's optional look against gifski (`docs/release.md`), the frames as PNGs, our GIF and ImageIO's
/// into `<folder>/<take>/`.
private func writeForTheOwner(_ folder: URL, take: GIFCorpus, frames: [[UInt8]], size: SIMD2<Int>, ours: Data, imageIO: Data) throws {
    let dir = folder.appending(path: take.rawValue)
    try FileManager.default.createDirectory(at: dir.appending(path: "frames"), withIntermediateDirectories: true)
    for (n, frame) in frames.enumerated() {
        let url = dir.appending(path: "frames").appending(path: String(format: "%03d.png", n)) as CFURL
        let png = try #require(CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(png, image(of: frame, size: size), nil)
        try #require(CGImageDestinationFinalize(png))
    }
    try ours.write(to: dir.appending(path: "toma.gif"))
    try imageIO.write(to: dir.appending(path: "imageio.gif"))
}

private func loadAverage() -> Double {
    var loads = [Double](repeating: 0, count: 3)
    return getloadavg(&loads, 3) > 0 ? loads[0] : .nan
}

private func megabytes(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1e6) }
private func kilobytes(_ bytes: Int) -> String { String(format: "%.0f KB", Double(bytes) / 1e3) }

// MARK: - Tuning (plan decisions 17 and 18)

/// The threshold maps of plan decision 18.
private enum ThresholdMap: String, Sendable, CaseIterable {
    /// 8 × 8 Bayer (`GIFQuantizer.thresholdMap`).
    case bayer8
    /// 64 × 64 blue noise by void-and-cluster from a fixed seed (`blueNoiseMap`).
    case blueNoise64

    var side: Int { self == .bayer8 ? GIFQuantizer.thresholdSide : 64 }
    var values: [Float] { self == .bayer8 ? GIFQuantizer.thresholdMap : blueNoiseMap }
}

/// A 64 × 64 blue-noise threshold map by void-and-cluster (Ulichney, 1993), from 410 cells placed with SplitMix64 of seed 1:
/// each cell's rank `i` as `(i + 0.5) / 4096`, row by row. The energy of a cell is the sum over the set cells of
/// `exp(−d² / (2 · 1.5²))`, `d` their distance on the torus; the tightest cluster is the set cell of most energy, the
/// largest void the empty one of least, the lower cell on ties. The prototype swaps its tightest cluster into the largest
/// void until that is the same cell; then its set cells take the ranks below its count from the last removed back, and
/// every other cell, in the order it fills the largest void, the ranks from its count up.
private let blueNoiseMap: [Float] = {
    let side = 64, n = side * side
    var kernel = [Double](repeating: 0, count: n)
    for dy in 0..<side {
        for dx in 0..<side {
            let x = Double(min(dx, side - dx)), y = Double(min(dy, side - dy))
            kernel[dy * side + dx] = exp(-(x * x + y * y) / (2 * 1.5 * 1.5))
        }
    }
    var energy = [Double](repeating: 0, count: n)
    var set = [Bool](repeating: false, count: n)
    func toggle(_ p: Int, _ on: Bool) {
        set[p] = on
        let px = p % side, py = p / side, sign = on ? 1.0 : -1.0
        for qy in 0..<side {
            let dy = (qy - py + side) % side
            for qx in 0..<side { energy[qy * side + qx] += sign * kernel[dy * side + (qx - px + side) % side] }
        }
    }
    func tightestCluster() -> Int {
        var best = -1
        for p in 0..<n where set[p] && (best < 0 || energy[p] > energy[best]) { best = p }
        return best
    }
    func largestVoid() -> Int {
        var best = -1
        for p in 0..<n where !set[p] && (best < 0 || energy[p] < energy[best]) { best = p }
        return best
    }
    var random = SplitMix64(seed: 1)
    let initial = n / 10
    var placed = 0
    while placed < initial {
        let p = Int(random.next() % UInt64(n))
        if !set[p] { toggle(p, true); placed += 1 }
    }
    while true {
        let cluster = tightestCluster()
        toggle(cluster, false)
        let void = largestVoid()
        toggle(void, true)
        if void == cluster { break }
    }
    let prototype = (set, energy)
    var rank = [Int](repeating: 0, count: n)
    var count = initial
    while count > 0 {
        let cluster = tightestCluster()
        toggle(cluster, false)
        count -= 1
        rank[cluster] = count
    }
    (set, energy) = prototype
    count = initial
    while count < n {
        let void = largestVoid()
        toggle(void, true)
        rank[void] = count
        count += 1
    }
    return rank.map { (Float($0) + 0.5) / Float(n) }
}()

/// One combination of the constants of plan decision 17 and the map of decision 18.
private struct GIFTuning: Hashable, Sendable, CustomStringConvertible {
    var map: ThresholdMap
    var dither: Float
    var reuseMeanError: Double
    var largeError: Double
    var largeErrorLimit: Double

    /// What the code has for `quality` (gifQuant-1).
    static func frozen(_ quality: GIFQuality) -> GIFTuning {
        GIFTuning(
            map: .bayer8, dither: quality.ditherStrength, reuseMeanError: quality.reuseMeanError,
            largeError: PaletteRules.largeError, largeErrorLimit: PaletteRules.largeErrorLimit)
    }

    var description: String {
        String(
            format: "%@ dither %.2f reuse %.3f large %.2f/%.0f%%", map.rawValue, dither, reuseMeanError, largeError,
            largeErrorLimit * 100)
    }
}

/// A command queue and a quantizer per threshold map, compiled once, used by one tuning at a time.
private struct TuningGPU: @unchecked Sendable {
    let queue: any MTLCommandQueue
    let quantizers: [ThresholdMap: GIFQuantizer]

    init() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        var quantizers: [ThresholdMap: GIFQuantizer] = [:]
        for map in ThresholdMap.allCases {
            quantizers[map] = try GIFQuantizer(device: device, thresholdMap: map.values, side: map.side)
        }
        self.quantizers = quantizers
    }
}

/// What gifQuant-1's pipeline gives of a take with a tuning.
private struct TunedGIF: Sendable {
    var bytes: Int
    var meanError: Double
    var newPalettes: Int
    var gif: Data
}

/// gifQuant-1's pipeline as `GIFEncoding` runs it, one frame after another, over frames already rendered, with `tuning`
/// in place of the constants and the map in the code: the GPU's histogram, the previous palette while
/// `meanOKLab ≤ reuseMeanError` and fewer than `largeErrorLimit` of the pixels are farther than `largeError` (the share
/// counted here on the CPU when `largeError` is not the kernel's), else a new one from the histogram; the composer, LZW
/// and the writer. The mean error is measured on the CPU like ImageIO's, against what the GIF shows (the composed frames
/// show the quantized ones exactly).
private func tunedGIF(
    _ frames: [[UInt8]], size: SIMD2<Int>, fps: Int, quality: GIFQuality, tuning: GIFTuning, gpu: TuningGPU, scratch: URL
) throws -> TunedGIF {
    let queue = gpu.queue
    let quantizer = gpu.quantizers[tuning.map]!
    let device = queue.device
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.x, height: size.y, mipmapped: false)
    descriptor.usage = [.shaderRead]
    descriptor.storageMode = .shared
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    func run<Pass>(_ encode: (any MTLCommandBuffer) throws -> Pass) throws -> Pass {
        let commands = try #require(queue.makeCommandBuffer())
        let pass = try encode(commands)
        commands.commit()
        commands.waitUntilCompleted()
        try #require(commands.status == .completed)
        return pass
    }
    let fd = open(scratch.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
    try #require(fd >= 0)
    defer { close(fd) }
    var writer = try GIFWriter(fileDescriptor: fd, width: size.x, height: size.y, loops: true)
    func write(_ frame: ComposedFrame) throws {
        let codeSize = LZWEncoder.minimumCodeSize(colors: frame.palette.count + 1)
        let data = try frame.indices.withUnsafeBufferPointer { try LZWEncoder.encode($0, minimumCodeSize: codeSize) }
        try writer.write(GIFImageBlock(
            x: frame.x, y: frame.y, width: frame.width, height: frame.height, palette: frame.palette,
            transparentIndex: frame.transparentIndex, delay: frame.delay, minimumCodeSize: codeSize, data: data))
    }
    let delays = GIFDelays.delays(frameCount: frames.count, fps: fps)
    var composer = GIFComposer(width: size.x, height: size.y)
    var previous: GIFPalette?
    var newPalettes = 0
    var errorSum = 0.0
    for (n, frame) in frames.enumerated() {
        frame.withUnsafeBytes {
            texture.replace(
                region: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: size.x * 4)
        }
        let histogram = try run { try quantizer.histogram(of: texture, into: $0) }
        var chosen: (palette: GIFPalette, indices: [UInt8])?
        if let previous {
            let mapped = try run { try quantizer.map(texture, palette: previous, dither: tuning.dither, into: $0) }
            let error = mapped.error()
            let indices = mapped.indices()
            let large = tuning.largeError == PaletteRules.largeError
                ? error.largeErrorFraction
                : Double(distances(frame, indices.map { previous.colors[Int($0)] }, largeError: Float(tuning.largeError)).large)
                    / Double(indices.count)
            if error.meanOKLab <= tuning.reuseMeanError && large < tuning.largeErrorLimit { chosen = (previous, indices) }
        }
        if chosen == nil {
            let palette = PaletteBuilder.build(histogram.result(), quality: quality)
            let mapped = try run { try quantizer.map(texture, palette: palette, dither: tuning.dither, into: $0) }
            chosen = (palette, mapped.indices())
            newPalettes += 1
        }
        let (palette, indices) = chosen!
        errorSum += distances(frame, indices.map { palette.colors[Int($0)] }).sum
        let quantized = QuantizedFrame(width: size.x, height: size.y, indices: indices, palette: palette, delay: delays[n])
        if let composed = composer.add(quantized) {
            try write(composed)
        }
        previous = palette
    }
    if let last = composer.finish() { try write(last) }
    try writer.finish()
    let gif = try Data(contentsOf: scratch)
    return TunedGIF(bytes: gif.count, meanError: errorSum / Double(frames.count * size.x * size.y), newPalettes: newPalettes, gif: gif)
}

// MARK: - Tests

@Suite(.serialized) struct GIFCorpusTests {
    /// gifQuant-1's palette of what a screen often is (Task 18's carry): a few flat colours (the window, the sidebar, the
    /// text, a button, a selection) with the antialiased edges of the text and of the button over two of them, and a
    /// shadow of a few levels. Fewer than 255 buckets, not all uniform: the flat ones covering 0.5 % or more whose bucket
    /// is nearly uniform are exact, largest first (not the selection: text edges fall in its bucket); every other bucket
    /// is one colour of its own (the median cut runs out of boxes before 255), so the palette is under 255 colours.
    /// Pinned.
    @Test func leftoverBucketsMakeAPaletteUnder255Colors() {
        var pixels: [SIMD3<UInt8>] = []
        let flats: [(SIMD3<UInt8>, Int)] = [
            (SIMD3(255, 255, 255), 30_000), (SIMD3(244, 244, 246), 8_000), (SIMD3(51, 51, 51), 2_500), (SIMD3(0, 122, 255), 1_200),
            (SIMD3(216, 216, 222), 900),
        ]
        for (color, count) in flats { pixels += [SIMD3<UInt8>](repeating: color, count: count) }
        func blend(_ a: SIMD3<UInt8>, over b: SIMD3<UInt8>, _ alpha: Int, of steps: Int) -> SIMD3<UInt8> {
            let mixed = SIMD3<Int>(truncatingIfNeeded: a) &* alpha &+ SIMD3<Int>(truncatingIfNeeded: b) &* (steps - alpha)
            return SIMD3<UInt8>(truncatingIfNeeded: (mixed &+ steps / 2) / steps)
        }
        // The text's edges over the window and the sidebar, the button's over the window: 15 and 7 levels.
        for alpha in 1..<16 {
            pixels += [SIMD3<UInt8>](repeating: blend(flats[2].0, over: flats[0].0, alpha, of: 16), count: 40)
            pixels += [SIMD3<UInt8>](repeating: blend(flats[2].0, over: flats[1].0, alpha, of: 16), count: 12)
        }
        for alpha in 1..<8 { pixels += [SIMD3<UInt8>](repeating: blend(flats[3].0, over: flats[0].0, alpha, of: 8), count: 20) }
        // A window's shadow over the sidebar: a few levels, each two neighbouring colours of one bucket.
        for level in 0..<6 {
            let gray = UInt8(236 - 6 * level)
            pixels += [SIMD3<UInt8>](repeating: SIMD3(gray, gray, gray &+ 2), count: 30)
            pixels += [SIMD3<UInt8>](repeating: SIMD3(gray &+ 1, gray &+ 1, gray &+ 3), count: 30)
        }
        let bgra = pixels.flatMap { pixel -> [UInt8] in [pixel.z, pixel.y, pixel.x, 255] }
        let histogram = bgra.withUnsafeBytes { ColorHistogram(bgra: $0, width: pixels.count, height: 1, bytesPerRow: pixels.count * 4) }
        let occupied = histogram.occupiedBuckets()
        #expect(occupied.count < 255 && !occupied.allSatisfy(histogram.isUniform), "not the exact palette of plan decision 15")
        let palette = PaletteBuilder.build(histogram, quality: .balanced)
        #expect(palette.exactCount == 4)
        #expect(Array(palette.colors.prefix(4)) == flats.prefix(4).map(\.0))
        #expect(!histogram.isNearlyUniform(occupied.first { histogram.roundedMean(of: $0) == flats[4].0 }!))
        #expect(palette.colors.dropFirst(4).contains(flats[4].0), "the selection is the colour of its bucket")
        #expect(palette.colors.count == occupied.count, "one colour per leftover bucket")
        #expect(palette.colors.count < 255)
        #expect(palette.colors.map { [$0.x, $0.y, $0.z] } == leftoverPalette, "gifQuant-1's palette of this frame")
    }

    /// A still frame keeps its palette at every quality (Task 20's carry): the error a frame mapped to its own palette is
    /// left with includes the noise of the quality's dither, and each quality's reuse thresholds sit above it, the mean and
    /// the share of pixels with a large error alike, with room to spare (a quarter over the mean, twice over the share; on
    /// this frame Light is 0.0120 against 0.025, Balanced 0.0091 against 0.015, and High, which takes a new palette
    /// sooner, 0.0119 against 0.015, the closest). Otherwise a camera that does not move would take
    /// a new palette on every frame, and the GIF would grow up to tenfold (the provisional High of plan decision 17,
    /// dither 1.0 and reuse ≤ 0.010, did: `GIFCorpusTests.gifCorpusTuning`). The frame is a camera's: smooth gradients with
    /// sensor noise of σ ≈ 3 levels, which leaves more error than any screen.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func eachQualityKeepsThePaletteOfAStillFrame() async throws {
        let width = 640, height = 360
        var random = SplitMix64(seed: 20)
        var bgra = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                // A warm wall going darker to the right, a face-like bright blob, and noise on every channel.
                let dx = Double(x - 330) / 150, dy = Double(y - 170) / 190
                let face = max(0, 1 - (dx * dx + dy * dy))
                let wall = SIMD3<Double>(140, 129, 116) - SIMD3(50, 46, 40) * (Double(x) / Double(width))
                let color = wall * (1 - face) + SIMD3<Double>(226, 180, 150) * face
                let r = random.next()
                for c in 0..<3 {
                    let noise = Double(Int(r >> (16 * c) & 0xFF) + Int(r >> (16 * c + 8) & 0xFF) - 255) / 32
                    bgra[(y * width + x) * 4 + 2 - c] = UInt8(min(255, max(0, (color[c] + noise).rounded())))
                }
            }
        }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let quantizer = try GIFQuantizer(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        bgra.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        let histogram = bgra.withUnsafeBytes { ColorHistogram(bgra: $0, width: width, height: height, bytesPerRow: width * 4) }
        func error(_ palette: GIFPalette, dither: Float) async throws -> PaletteError {
            let commands = try #require(queue.makeCommandBuffer())
            let pass = try quantizer.map(texture, palette: palette, dither: dither, into: commands)
            commands.commit()
            await commands.completed()
            try #require(commands.status == .completed)
            return pass.error()
        }
        for quality in GIFQuality.allCases {
            let palette = PaletteBuilder.build(histogram, quality: quality)
            let own = try await error(palette, dither: quality.ditherStrength)
            #expect(PaletteBuilder.shouldReuse(own, quality: quality), "\(quality): \(own)")
            #expect(own.meanOKLab * 1.25 <= quality.reuseMeanError, "\(quality): \(own.meanOKLab) against \(quality.reuseMeanError)")
            #expect(own.largeErrorFraction * 2 <= PaletteRules.largeErrorLimit, "\(quality): \(own.largeErrorFraction)")
        }
        // What the provisional High would have been left with: over its threshold.
        let provisional = try await error(PaletteBuilder.build(histogram, quality: .high), dither: 1.0)
        #expect(provisional.meanOKLab > 0.010, "the provisional High rebuilt the palette on every frame of a still camera")
    }

    /// The palette of a frame that fills all 255 colours (the median cut and k-means at work: tiles of a gradient, of noise
    /// and of three flat colours) is pinned too: gifQuant-1 gives these colours, in this order, on every Mac.
    @Test func fullPaletteIsPinned() {
        var random = SplitMix64(seed: 25)
        let flats: [SIMD3<UInt8>] = [SIMD3(250, 250, 250), SIMD3(30, 30, 34), SIMD3(255, 59, 48)]
        var bgra: [UInt8] = []
        let width = 320, height = 180
        for y in 0..<height {
            for x in 0..<width {
                let color: SIMD3<UInt8> = switch (x / 40 + y / 45) % 5 {
                case 0, 1: SIMD3(UInt8(x * 255 / (width - 1)), UInt8(y * 255 / (height - 1)), UInt8((x + y) % 256))
                case 2: SIMD3(UInt8.random(in: 0...255, using: &random), UInt8.random(in: 0...255, using: &random), 128)
                default: flats[(x / 40 + y / 45) % 3]
                }
                bgra += [color.z, color.y, color.x, 255]
            }
        }
        let histogram = bgra.withUnsafeBytes { ColorHistogram(bgra: $0, width: width, height: height, bytesPerRow: width * 4) }
        let palette = PaletteBuilder.build(histogram, quality: .balanced)
        #expect(palette.colors.count == 255 && palette.exactCount == 3)
        #expect(Set(palette.colors.prefix(3)) == Set(flats), "the flat colours first")
        // FNV-1a of the colours' bytes, in order.
        let hash = palette.colors.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { hash, color in
            [color.x, color.y, color.z].reduce(hash) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 }
        }
        #expect(hash == fullPaletteHash, "gifQuant-1's palette of this frame: 0x\(String(hash, radix: 16))")
    }

    /// The bench of 1c design §15 and §16.1 (Task 25), with the criterion the coordinator put in place of "≤ 50 % of
    /// ImageIO's size" (design §4.3 assumed an ImageIO that neither crops nor leaves unchanged pixels transparent; on
    /// macOS 26.6 it does both, with one palette). For each take of the corpus, at 800 px, 15 fps, Balanced, with the
    /// dither, our GIF (`GIFExporter.export`) against ImageIO's of the same rendered frames:
    /// - a mean error in OKLab no larger than ImageIO's on at least half the takes;
    /// - the export's memory bounded: what it allocates on the heap at its most (`heapInUse`, as ImageIO's is measured,
    ///   the first take's with the process's caches) is under a fifth of the take's frames, all of which ImageIO keeps
    ///   until it finalizes: 43.2 MB, where at most 11.4 MB was measured (the frames in flight are GPU textures, outside
    ///   the heap; that the whole process's footprint does not grow with the duration, `make crash-test`'s GIF case
    ///   checks);
    /// - no regression of size or of palettes: each take's GIF within 1.2 times the bytes it had when gifQuant-1 was
    ///   frozen, and at most 5 more new palettes than then (`frozenCorpus`): a palette rebuilt on every frame, the error
    ///   of the provisional High, is 150;
    /// - the estimate (`GIFEstimate.estimates`, with its preview from the start) within 30 % of the size;
    /// - the size against ImageIO's printed as measured, not asserted.
    /// Prints a line per take and the load. With `TOMA_GIF_CORPUS_OUT` set to a folder, also writes there the frames as
    /// PNGs and both GIFs, for the owner's look against gifski.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"), .timeLimit(.minutes(60)))
    func gifCorpusBeatsImageIO() async throws {
        let output = ProcessInfo.processInfo.environment["TOMA_GIF_CORPUS_OUT"].map { URL(fileURLWithPath: $0) }
        var rows: [String] = []
        var failures: [String] = []
        var errorsNoLarger = 0
        for take in GIFCorpus.allCases {
            try await withTemporaryDirectory { dir in
                let (project, document) = try await take.make(in: dir)
                let settings = GIFSettings(longSide: 800, fps: 15, quality: .balanced, range: .whole(TimeMap(sequence: document.sequence)))
                let size = settings.outputSize(aspect: document.aspect)

                let newPalettes = Mutex(0)
                let exporter = GIFExporter(project: project, document: document, settings: settings) { _, _, isNew in
                    if isNew { newPalettes.withLock { $0 += 1 } }
                }
                let destination = dir.appending(path: "ours.gif")
                let (_, ourHeap) = try await peakHeapGrowth { try await exporter.export(to: destination) { _ in } }
                let ours = try Data(contentsOf: destination)
                let frames = try await renderedFrames(project, document, settings: settings)
                let ourError = try meanError(of: ours, frames: frames, fps: settings.fps)
                let imageIO = try imageIOGIF(frames, size: size, fps: settings.fps)
                let imageIOError = try meanError(of: imageIO.gif, frames: frames, fps: settings.fps)
                let preview = try await GIFEstimate.preview(
                    project: project, document: document, settings: settings, playhead: settings.range.start)
                var estimates: [GIFEstimateResult] = []
                let stream = GIFEstimate.estimates(project: project, document: document, settings: settings, preview: preview)
                for try await estimate in stream {
                    estimates.append(estimate)
                }
                let estimate = try #require(estimates.last)
                if let output {
                    try writeForTheOwner(output, take: take, frames: frames, size: size, ours: ours, imageIO: imageIO.gif)
                }

                let ratio = Double(ours.count) / Double(imageIO.gif.count)
                let off = Double(estimate.bytes) / Double(ours.count) - 1
                let firstOff = Double(estimates.first!.bytes) / Double(ours.count) - 1
                let palettes = newPalettes.withLock { $0 }
                rows.append(String(
                    format: "%@ ours %@ (error %.5f, %d new palettes)  ImageIO %@ (error %.5f)  size %.1f %% of ImageIO's  "
                        + "estimate %@ %+.0f %% (first %@ %+.0f %%)  heap at most: ours %@, ImageIO %@ with the %d frames added "
                        + "and %@ finalizing, %@ once released (the GIF aside)",
                    take.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0), kilobytes(ours.count), ourError, palettes,
                    kilobytes(imageIO.gif.count), imageIOError, ratio * 100, kilobytes(Int(estimate.bytes)), off * 100,
                    kilobytes(Int(estimates.first!.bytes)), firstOff * 100, megabytes(ourHeap), megabytes(imageIO.memory.added),
                    frames.count, megabytes(imageIO.memory.finalizing), megabytes(imageIO.memory.released)))
                if ourError <= imageIOError { errorsNoLarger += 1 }
                if ourHeap * 5 >= frames.count * size.x * size.y * 4 {
                    failures.append("\(take): the export allocated \(ourHeap) bytes at its most")
                }
                let frozen = try #require(frozenCorpus[take])
                if Double(ours.count) > 1.2 * Double(frozen.bytes) {
                    failures.append("\(take): \(ours.count) bytes, over 1.2 times the \(frozen.bytes) it had when gifQuant-1 was frozen")
                }
                if palettes > frozen.palettes + 5 {
                    failures.append("\(take): \(palettes) new palettes, where gifQuant-1 took \(frozen.palettes)")
                }
                if abs(off) > 0.3 { failures.append("\(take): estimate \(estimate.bytes) for \(ours.count) bytes") }
            }
        }
        if errorsNoLarger * 2 < GIFCorpus.allCases.count {
            failures.append("the error is no larger than ImageIO's on \(errorsNoLarger) of \(GIFCorpus.allCases.count) takes")
        }
        print("gifQuant-1 on the corpus, 800 px, 15 fps, Balanced, load \(String(format: "%.1f", loadAverage())):")
        for row in rows { print("  " + row) }
        print("  error no larger than ImageIO's on \(errorsNoLarger) of \(GIFCorpus.allCases.count) takes")
        #expect(failures.isEmpty, "\(failures)")
    }

    /// The measurement that chose gifQuant-1's constants (Task 25, Step 2; `TOMA_BENCH=1 TOMA_GIF_TUNING=1`): the corpus
    /// at 800 px and 15 fps, rendered once per take, through the pipeline with each combination of the threshold map
    /// (plan decision 18) and three values around each constant of decision 17 (the dither and the reuse threshold
    /// crossed; the large-error rule on its own, around the provisional values and around the code's), each against
    /// ImageIO; for Balanced, also less dither and none, past the grid. Prints a line per combination and take, then per
    /// combination whether it passes `gifCorpusBeatsImageIO`'s error criterion, its worst size and error against
    /// ImageIO's and the corpus's total size. It first checks that the pipeline here, with the code's constants, gives the
    /// exporter's bytes.
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1" && ProcessInfo.processInfo.environment["TOMA_GIF_TUNING"] == "1"),
        .timeLimit(.minutes(120)))
    func gifCorpusTuning() async throws {
        let quality = GIFQuality(rawValue: ProcessInfo.processInfo.environment["TOMA_GIF_QUALITY"] ?? "balanced") ?? .balanced
        let gpu = try TuningGPU()
        let frozen = GIFTuning.frozen(quality)
        // Around the provisional values of plan decision 17 for the quality (dither, reuse): Light 1.0 and 0.025, Balanced
        // 0.75 and 0.015, High 1.0 and 0.010 (and 0.020 for High, past its three: its 0.010 is under its own dither's error).
        let (provisional, dithers, reuses): ((Float, Double), [Float], [Double]) = switch quality {
        case .light: ((1.0, 0.025), [0.75, 1.0, 1.25], [0.020, 0.025, 0.030])
        case .balanced: ((0.75, 0.015), [0.5, 0.75, 1.0], [0.010, 0.015, 0.020])
        case .high: ((1.0, 0.010), [0.75, 1.0, 1.25], [0.005, 0.010, 0.015, 0.020])
        }
        var tunings: [GIFTuning] = []
        for map in ThresholdMap.allCases {
            for dither in dithers {
                for reuse in reuses {
                    tunings.append(GIFTuning(map: map, dither: dither, reuseMeanError: reuse, largeError: 0.06, largeErrorLimit: 0.02))
                }
            }
            // The large-error rule on its own, around the provisional dither and reuse and around the code's.
            var centers = [provisional]
            if (frozen.dither, frozen.reuseMeanError) != provisional { centers.append((frozen.dither, frozen.reuseMeanError)) }
            for (dither, reuse) in centers {
                for (large, limit) in [(0.04, 0.02), (0.08, 0.02), (0.06, 0.01), (0.06, 0.03)] {
                    tunings.append(GIFTuning(map: map, dither: dither, reuseMeanError: reuse, largeError: large, largeErrorLimit: limit))
                }
            }
        }
        // Beyond the three values, to see how far from the criteria the grid is: less dither, none, a looser reuse.
        let beyond = [(Float(0.25), 0.015), (0.25, 0.03), (0, 0.015), (0, 0.03), (0.5, 0.03)].map { dither, reuse in
            GIFTuning(map: .bayer8, dither: dither, reuseMeanError: reuse, largeError: 0.06, largeErrorLimit: 0.02)
        }
        if quality == .balanced { tunings += beyond.filter { !tunings.contains($0) } }
        if let only = ProcessInfo.processInfo.environment["TOMA_GIF_TUNING_MAP"], let map = ThresholdMap(rawValue: only) {
            tunings = tunings.filter { $0.map == map }
        }
        if !tunings.contains(frozen) { tunings.insert(frozen, at: 0) }

        var results: [GIFTuning: [(take: GIFCorpus, gif: TunedGIF, imageIO: Int, imageIOError: Double)]] = [:]
        for take in GIFCorpus.allCases {
            try await withTemporaryDirectory { dir in
                let (project, document) = try await take.make(in: dir)
                let settings = GIFSettings(longSide: 800, fps: 15, quality: quality, range: .whole(TimeMap(sequence: document.sequence)))
                let size = settings.outputSize(aspect: document.aspect)
                let frames = try await renderedFrames(project, document, settings: settings)
                let imageIO = try imageIOGIF(frames, size: size, fps: settings.fps)
                let imageIOError = try meanError(of: imageIO.gif, frames: frames, fps: settings.fps)
                print(String(
                    format: "%@: ImageIO %@, error %.5f; load %.1f", take.rawValue, kilobytes(imageIO.gif.count), imageIOError, loadAverage()))

                // The pipeline here is the exporter's.
                let exporter = GIFExporter(project: project, document: document, settings: settings)
                let exported = try await exporter.encodeInMemory(range: settings.range)
                let scratch = dir.appending(path: "tuned.gif")
                let check = try await offThePool {
                    try tunedGIF(frames, size: size, fps: settings.fps, quality: quality, tuning: frozen, gpu: gpu, scratch: scratch)
                }
                #expect(check.gif == exported, "\(take): the pipeline of the tuning is the exporter's")
                let exportedError = try meanError(of: exported, frames: frames, fps: settings.fps)
                #expect(abs(check.meanError - exportedError) < 1e-9, "\(take): \(check.meanError) \(exportedError)")

                for tuning in tunings {
                    let gif = try await offThePool {
                        try tunedGIF(frames, size: size, fps: settings.fps, quality: quality, tuning: tuning, gpu: gpu, scratch: scratch)
                    }
                    results[tuning, default: []].append((take, gif, imageIO.gif.count, imageIOError))
                    print(String(
                        format: "  %@  %@ %.1f %%  error %.5f (ImageIO %.5f)  %d new palettes", tuning.description, kilobytes(gif.bytes),
                        Double(gif.bytes) / Double(imageIO.gif.count) * 100, gif.meanError, imageIOError, gif.newPalettes))
                }
            }
        }
        print("Per combination, \(quality.rawValue), over the four takes (load \(String(format: "%.1f", loadAverage()))):")
        let ranked = tunings.map { tuning -> (GIFTuning, passes: Bool, total: Int, worstSize: Double, worstError: Double) in
            let takes = results[tuning]!
            let sizes = takes.map { Double($0.gif.bytes) / Double($0.imageIO) }
            let errors = takes.map { $0.gif.meanError / $0.imageIOError }
            // `gifCorpusBeatsImageIO`'s criterion for the error: no larger than ImageIO's on at least half the takes. (It
            // chose gifQuant-1 against "≤ 50 % of ImageIO's size" too, which nothing reached: see the size columns.)
            let passes = errors.filter { $0 <= 1 }.count * 2 >= errors.count
            return (tuning, passes, takes.reduce(0) { $0 + $1.gif.bytes }, sizes.max()!, errors.max()!)
        }
        for row in ranked.sorted(by: { ($0.passes ? 0 : 1, $0.total) < ($1.passes ? 0 : 1, $1.total) }) {
            print(String(
                format: "  %@  %@  total %@  worst size %.1f %%  worst error %.3f × ImageIO's%@", row.passes ? "PASS" : "fail",
                row.0.description, kilobytes(row.total), row.worstSize * 100, row.worstError,
                beyond.contains(row.0) ? "  (beyond the grid)" : ""))
        }
    }
}

/// What each take of the corpus gave when gifQuant-1 was frozen (Task 25; the same bytes on every run of this Mac): the
/// GIF's bytes and the new palettes of its 150 frames. The camera full screen's are those of the stand-in it had then
/// (the camera recorded as the screen, filling the output), kept as its budget once the layout drew it (Task 13).
private let frozenCorpus: [GIFCorpus: (bytes: Int, palettes: Int)] = [
    .tutorial: (1_849_888, 1), .browserScroll: (2_698_969, 2), .wallpaperBubble: (740_716, 1), .cameraFull: (16_573_149, 1),
]

/// gifQuant-1's palette of the frame of `leftoverBucketsMakeAPaletteUnder255Colors`, as R, G, B.
private let leftoverPalette: [[UInt8]] = [
    [255, 255, 255], [244, 244, 246], [51, 51, 51], [0, 122, 255], [63, 63, 63], [191, 222, 255], [216, 216, 222], [64, 155, 255],
    [32, 139, 255], [159, 205, 255], [179, 179, 179], [140, 140, 140], [128, 128, 128], [115, 115, 115], [165, 165, 165],
    [89, 89, 89], [135, 135, 136], [128, 189, 255], [123, 123, 124], [196, 196, 197], [212, 212, 214], [223, 238, 255],
    [207, 207, 208], [172, 172, 173], [87, 87, 88], [227, 227, 228], [111, 111, 112], [231, 231, 232], [77, 77, 77],
    [101, 101, 102], [153, 153, 153], [96, 172, 255], [189, 189, 190], [148, 148, 149], [236, 236, 238], [204, 204, 204],
    [64, 64, 64],
]

/// FNV-1a of gifQuant-1's palette of the frame of `fullPaletteIsPinned`.
private let fullPaletteHash: UInt64 = 0x725E_C48E_13F7_B1A5
