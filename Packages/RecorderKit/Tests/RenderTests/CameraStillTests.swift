// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ProjectFormat
import RecorderKitTestSupport
@testable import Render
import SyntheticCapture
import Testing

// The camera's frame at the playhead, for the small view of Manual framing and the Color tiles of the Camera tab (plan
// 2b decision 19): the frame of that instant, exactly, as a picture.

/// A take of two segments of the synthetic camera, 640 × 360 at 30 fps, frames numbered by their colour: the first of 2 s
/// from `base`, the second of 1 s from `base + 3 s` (a gap of 1 s between them).
private func cameraProject(in dir: URL) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: cameraID, kind: .camera, source: cameraSource,
        segments: [VideoSegmentSpec(start: base, seconds: 2), VideoSegmentSpec(start: base.adding(seconds: 3), seconds: 1)])
    return try builder.write()
}

/// The palette index of `image`, read near its bottom-right corner, away from the moving white square.
private func frameIndex(of image: CGImage) throws -> Int {
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    try #require(drawn)
    let i = ((height - 4) * width + (width - 4)) * 4
    return SampleFactory.frameIndex(nearestTo: SIMD4(bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]))
}

/// The sRGB bytes (RGBA) of `image`'s pixel (`x`, `y`) from the top.
private func rgba(of image: CGImage, x: Int, y: Int) -> SIMD4<UInt8> {
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    let i = (y * width + x) * 4
    return SIMD4(bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
}

/// A picture `width` × `height` of the sRGB colour `color` (RGBA).
private func picture(_ color: SIMD4<UInt8>, width: Int = 4, height: Int = 2) -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for i in 0..<(width * height) {
        for c in 0..<4 { bytes[i * 4 + c] = color[c] }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

@Suite struct CameraStillTests {
    @Test func stillIsTheFrameAtTheTime() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await cameraProject(in: dir)
            // 1.5 s in: frame 45 of the first segment (inside its 33 ms, away from the rounding of its start).
            let still = try #require(
                await CameraStill.frame(project: project, track: cameraID, at: base.adding(seconds: 1.51), maxPixelSide: 320))
            #expect(still.frameSize == SIMD2(640, 360))
            #expect(still.image.width == 320 && still.image.height == 180)
            #expect(try frameIndex(of: still.image) == 45)
            // In the second segment, numbered after the first's 60 frames: 0.5 s in is its frame 15, the track's 75.
            let second = try #require(
                await CameraStill.frame(project: project, track: cameraID, at: base.adding(seconds: 3.51), maxPixelSide: 640))
            #expect(second.image.width == 640 && second.image.height == 360)
            #expect(try frameIndex(of: second.image) == 75 % 64)
        }
    }

    @Test func afterItsSegmentTheLastFrameIsHeld() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await cameraProject(in: dir)
            // In the gap after the first segment, as the render draws the camera: its last frame, 59.
            let held = try #require(
                await CameraStill.frame(project: project, track: cameraID, at: base.adding(seconds: 2.5), maxPixelSide: 160))
            #expect(try frameIndex(of: held.image) == 59)
            // Past the take's end: the last frame of the last segment, the track's 89.
            let last = try #require(
                await CameraStill.frame(project: project, track: cameraID, at: base.adding(seconds: 9), maxPixelSide: 160))
            #expect(try frameIndex(of: last.image) == 89 % 64)
        }
    }

    @Test func nothingOutsideTheTrack() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await cameraProject(in: dir)
            // Before the camera's first frame, a track the take does not have, and a size that is no size.
            let before = await CameraStill.frame(project: project, track: cameraID, at: base.adding(seconds: -1), maxPixelSide: 160)
            let other = await CameraStill.frame(project: project, track: "nope", at: base.adding(seconds: 1), maxPixelSide: 160)
            let empty = await CameraStill.frame(project: project, track: cameraID, at: base.adding(seconds: 1), maxPixelSide: 0)
            #expect(before == nil && other == nil && empty == nil)
            // A segment whose file is gone.
            let file = try #require(project.take.track(cameraID)?.segments.first?.file)
            try FileManager.default.removeItem(at: project.package.fileURL(file))
            let gone = await CameraStill.frame(project: project, track: cameraID, at: base.adding(seconds: 1), maxPixelSide: 160)
            #expect(gone == nil)
        }
    }

    @Test func aLookIsTheLookOfEachPixel() throws {
        let gray = picture(SIMD4(128, 128, 128, 255))
        // Natural keeps the picture as it is.
        let natural = try #require(CameraStill.withLook(.natural, gray))
        #expect(rgba(of: natural, x: 1, y: 1) == SIMD4(128, 128, 128, 255))
        // Warm is the look's own numbers (`CameraLooks.apply`), pixel by pixel: redder, less blue.
        let warm = try #require(CameraStill.withLook(.warm, gray))
        let expected = CameraLooks.apply(.warm, to: SIMD3(repeating: 128.0 / 255))
        let shown = rgba(of: warm, x: 3, y: 0)
        #expect(abs(Int(shown.x) - Int((expected.x * 255).rounded())) <= 1)
        #expect(abs(Int(shown.z) - Int((expected.z * 255).rounded())) <= 1)
        #expect(shown.x > 128 && shown.z < 128 && shown.w == 255)
        // Black and white leaves no colour.
        let mono = try #require(CameraStill.withLook(.mono, picture(SIMD4(200, 40, 90, 255))))
        let m = rgba(of: mono, x: 0, y: 1)
        let channels: [UInt8] = [m.x, m.y, m.z]
        #expect(Set(channels).count == 1)
        #expect(mono.width == 4 && mono.height == 2)
        // Scaled down to fit, never up; a size of none is no picture.
        let small = try #require(CameraStill.withLook(.cool, picture(SIMD4(90, 90, 90, 255), width: 320, height: 180), maxPixelSide: 160))
        #expect(small.width == 160 && small.height == 90)
        #expect(CameraStill.withLook(.cool, gray, maxPixelSide: 100)?.width == 4)
        #expect(CameraStill.withLook(.cool, gray, maxPixelSide: 0) == nil)
    }

    @Test func theSampleSceneIsAPicture() {
        let scene = CameraStill.sampleScene(width: 96, height: 72)
        #expect(scene?.width == 96 && scene?.height == 72)
        #expect(CameraStill.sampleScene(width: 0, height: 72) == nil)
    }
}
