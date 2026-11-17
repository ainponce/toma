// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreVideo
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
@testable import Render
import Synchronization
import Testing

// The preview is the export with the camera layouts (1c design §16.1, "Vista previa = export"): the five layouts, smooth
// and instant transitions, the zoom inside the screen's card and the mirrored camera. The preview's snapshot is, byte for
// byte, the frame the export draws (`render(at:into:completion:)`, decoding ahead through the prefetchers, also 1 s ahead
// of a block border), and the MP4 decodes to it. The export's tests, because the MP4 is the export's.

private let parityCameraID = "camera"
private let parityCameraSource = TrackSource(name: "Synthetic Camera", deviceUniqueID: "synthetic-camera")

private func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

/// The output seconds of frame `n` at `fps`.
private func frameSeconds(_ n: Int, _ fps: Int) -> Double { Double(TimeMap.frameTime(n, frameRate: fps)) / 1e9 }

/// The bytes of the frames of `keep` the export draws, by index.
private final class KeptFrames: Sendable {
    private let keep: Set<Int>
    private let kept = Mutex<[Int: [UInt8]]>([:])

    init(_ keep: Set<Int>) { self.keep = keep }

    var bytes: [Int: [UInt8]] { kept.withLock { $0 } }

    var sink: MP4Exporter.FrameSink {
        { [self] index, pixelBuffer in
            guard keep.contains(index) else { return }
            let bytes = packedBytes(of: pixelBuffer)
            kept.withLock { $0[index] = bytes }
        }
    }
}

/// A take of 7 s: the display (640 × 360 pt) and a 4:3 camera, the cursor going round and a click at 1.5 s.
private func layoutTake(in dir: URL) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: "Layouts")
    try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 7)])
    try await builder.addVideoTrack(
        id: parityCameraID, kind: .camera, source: parityCameraSource,
        segments: [VideoSegmentSpec(start: base, seconds: 7, width: 640, height: 480)])
    try builder.addEvents((0..<(7 * 60)).map { i in
        let angle = Double(i) / 60 * 2
        return InputEvent(t: at(Double(i) / 60), kind: .cursor(x: 320 + 200 * cos(angle), y: 180 + 120 * sin(angle)))
    })
    try builder.addEvents([
        InputEvent(t: at(1.5), kind: .mouseDown(.left, x: 300, y: 150)), InputEvent(t: at(1.6), kind: .mouseUp(.left, x: 300, y: 150)),
    ])
    return try builder.write()
}

/// Bubble (the project's), a split from 1 s with a fixed zoom in its card, Camera only from 2.5 s, Camera full screen from
/// 3.5 s (instant, both ways), Screen only from 4.5 s and the Bubble again from 5.5 s; the camera mirrored, with a
/// border and a shadow; a background of one colour (a wallpaper's grain would rule the SSIM).
private func layoutDocument(of project: LoadedProject) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    document.frameRate = 60
    document.style.background = .color(RGBA(0.18, 0.22, 0.3, 1))
    document.style.shadow = 0.5
    document.style.cornerRadius = 0.02
    document.cursor.clickEffect = "ripple-1"
    document.camera.show = true
    document.camera.mirror = true
    document.camera.border = CameraBorder(width: 1, color: RGBA(1, 1, 1, 1))
    document.camera.shadow = 0.4
    func block(_ number: Int, _ kind: LayoutKind, _ from: Double, _ to: Double, instant: Bool = false) -> LayoutBlock {
        LayoutBlock(
            id: String(format: "l-%08x", number), take: takeID, start: at(from), end: at(to), kind: kind, instant: instant,
            bubble: nil, split: kind == .split ? SplitLayout() : nil)
    }
    document.camera.layouts = [
        block(1, .split, 1, 2.5), block(2, .cameraOnly, 2.5, 3.5), block(3, .cameraFull, 3.5, 4.5, instant: true),
        block(4, .screenOnly, 4.5, 5.5),
    ]
    document.zoom.motionBlur = 1
    document.zoom.regions = [
        ZoomRegion(
            id: "z-00000001", take: takeID, start: at(1.1), end: at(2.4), origin: .user, depth: 2, focus: .fixed(x: 0.3, y: 0.3),
            instant: false),
    ]
    return document
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(5)))
func previewSnapshotEqualsTheExportFrameWithLayouts() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await layoutTake(in: dir)
        let document = layoutDocument(of: project)
        let size = SIMD2(640, 360)
        let last = TimeMap(sequence: document.sequence).frameCount(frameRate: 60) - 1
        #expect(last == 419)
        // Each border (60, 150, 210, 270, 330), halfway through each smooth transition (a fifth of a second in: the
        // spring is about two thirds of the way), the zoom moving inside the card, and the last frame.
        let compared = [0, 60, 72, 100, 150, 162, 210, 225, 270, 330, 342, last]
        let kept = KeptFrames(Set(compared))
        let destination = dir.appending(path: "layouts.mp4")
        try await MP4Exporter(
            project: project, document: document, settings: ExportSettings(outputSize: size, framesPerSecond: 60, quality: .high),
            frameSink: kept.sink
        ).export(to: destination) { _ in }

        let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
        let preview = PreviewRenderer(renderer: renderer)
        let snapshots = try await offThePool { try compared.map { try preview.snapshot(at: frameSeconds($0, 60)) } }
        let drawn = kept.bytes
        for (n, snapshot) in zip(compared, snapshots) {
            let exported = try #require(drawn[n], "frame \(n) was not drawn")
            #expect(snapshot == exported, "frame \(n): the preview's snapshot is the frame the export draws")
            let decoded = try await videoFrame(of: destination, nearest: frameSeconds(n, 60))
            #expect(abs(decoded.time - frameSeconds(n, 60)) < 0.001)
            let ssim = ssimLuma(decoded.bytes, exported, width: size.x, height: size.y)
            #expect(ssim >= 0.98, "frame \(n): SSIM \(ssim)")
        }

        // What was compared is the layouts: mid-transition frames, the card's zoom, the camera alone and full screen.
        let scene = renderer.scene
        func frame(_ n: Int) -> RenderFrame { scene.frame(at: frameSeconds(n, 60)) }
        #expect(frame(72).card.map { $0.mix > 0 && $0.mix < 1 } == true, "Bubble to Split under way")
        #expect(frame(100).card?.content.depth ?? 1 > 1.2, "the zoom inside the card")
        #expect(frame(162).screenOpacity.map { $0 > 0 && $0 < 1 } == true, "Split to Camera only under way")
        #expect(frame(225).coveredByCamera && frame(225).screen == nil, "Camera full screen")
        #expect(frame(342).camera.map { $0.opacity > 0 && $0.opacity < 1 } == true, "the camera coming back")
        #expect(frame(60).camera?.mirror == true)
    }
}
