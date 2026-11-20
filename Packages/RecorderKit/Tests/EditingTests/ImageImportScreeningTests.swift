// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import ProjectFormat
import RecorderKitTestSupport
import Testing
import UniformTypeIdentifiers
@testable import Editing

// A TIFF, a GIF or a PDF is converted once, as `importAsset` screens it: `place` writes the PNG it is handed, however
// many times a full disk makes it try, and never reads (or converts) the file again (phase 3a plan, Task A4 review).

/// A 24 × 16 red image of `type`.
private func image(_ type: UTType) throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: 24, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Test func aConvertedImageIsPlacedFromItsPNG() throws {
    try withTemporaryDirectory { dir in
        let package = ProjectPackage(url: dir.appending(path: "Fixture.toma", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: package.url, withIntermediateDirectories: true)
        let gif = dir.appending(path: "Animation.gif")
        try image(.gif).write(to: gif)

        guard case let .accepted(converted?) = AssetImport.screened(gif, as: .image) else {
            Issue.record("a GIF is screened with its PNG")
            return
        }
        // The file is gone by the time it is placed: the PNG screened is what goes in, named by its own bytes.
        try FileManager.default.removeItem(at: gif)
        let name = try AssetImport.place(gif, into: package, converted: converted)
        let hash = SHA256.hash(data: converted).prefix(16).map { String(format: "%02x", $0) }.joined()
        #expect(name == "assets/\(hash).png")
        #expect(try Data(contentsOf: package.url.appending(path: name)) == converted)
        // Without it, the file is read and converted there.
        #expect(throws: AssetImport.Failure.self) { try AssetImport.place(gif, into: package) }

        // A PNG is screened with nothing converted, and cloned; one that does not decode is refused.
        let png = dir.appending(path: "Background.png")
        try image(.png).write(to: png)
        guard case .accepted(converted: nil) = AssetImport.screened(png, as: .image) else {
            Issue.record("a PNG is cloned, never converted")
            return
        }
        let broken = dir.appending(path: "Broken.tiff")
        try Data(repeating: 7, count: 512).write(to: broken)
        guard case .refused(.notAnImage) = AssetImport.screened(broken, as: .image) else {
            Issue.record("a TIFF that does not convert is refused")
            return
        }
    }
}
