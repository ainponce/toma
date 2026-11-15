// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Testing

@Suite struct CameraStyleTests {
    /// The prototype's screen: 1200 × 750 points.
    private static let reference = Rect(x: 0, y: 0, width: 1200, height: 750)

    @Test func defaultStyleIsAMediumCircleBottomTrailing() {
        #expect(CameraStyle.default == CameraStyle(shape: .circle, size: 0.24, anchor: .bottomTrailing))
        #expect(CameraStyle.default.frame(in: Self.reference) == CameraFrame(rect: Rect(x: 996, y: 546, width: 180, height: 180), cornerRadius: 90))
        #expect(CameraShape.allCases.map(\.aspect) == [1, 1, 3.0 / 4, 16.0 / 9])
        #expect((CameraStyle.small, CameraStyle.medium, CameraStyle.large, CameraStyle.marginFraction) == (0.17, 0.24, 0.33, 0.032))
    }

    @Test func boxesKeepTheAreaOfTheSide() {
        let portrait = CameraStyle(shape: .portrait, size: 0.24, anchor: .topLeading).frame(in: Self.reference)
        expect(portrait, is: Rect(x: 24, y: 24, width: 155.885, height: 207.846), radius: 20)
        let landscape = CameraStyle(shape: .landscape, size: 0.17, anchor: .bottom).frame(in: Self.reference)
        expect(landscape, is: Rect(x: 515, y: 630.375, width: 170, height: 95.625), radius: 18)
        let square = CameraStyle(shape: .roundedSquare, size: 0.33, anchor: .bottomTrailing).frame(in: Self.reference)
        expect(square, is: Rect(x: 1200 - 247.5 - 24, y: 750 - 247.5 - 24, width: 247.5, height: 247.5), radius: 64.35)
        // Every box has the area of the square of its side.
        for (frame, side) in [(portrait, 180.0), (landscape, 127.5)] {
            #expect(abs(frame.rect.width * frame.rect.height - side * side) < 0.01)
        }
    }

    @Test func framesScaleWithTheRegionHeight() {
        let full = Rect(x: 0, y: 0, width: 1920, height: 1080)
        expect(CameraStyle.default.frame(in: full), is: Rect(x: 1626.24, y: 786.24, width: 259.2, height: 259.2), radius: 129.6)
        // A display up and to the left of the main one: the same box, moved by its origin.
        let secondary = Rect(x: -1920, y: -200, width: 1920, height: 1080)
        expect(CameraStyle.default.frame(in: secondary), is: Rect(x: 1626.24 - 1920, y: 786.24 - 200, width: 259.2, height: 259.2), radius: 129.6)
        // The middles of the edges: centered on the other axis.
        let leading = CameraStyle(shape: .circle, size: 0.24, anchor: .leading).frame(in: full)
        expect(leading, is: Rect(x: 34.56, y: (1080 - 259.2) / 2, width: 259.2, height: 259.2), radius: 129.6)
        let top = CameraStyle(shape: .circle, size: 0.24, anchor: .top).frame(in: full)
        expect(top, is: Rect(x: (1920 - 259.2) / 2, y: 34.56, width: 259.2, height: 259.2), radius: 129.6)
    }

    @Test func cameraStyleRoundTripsAsJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(CameraStyle.default), as: UTF8.self)
        #expect(json == #"{"anchor":"bottomTrailing","shape":"circle","size":0.24}"#)
        for style in [CameraStyle.default, CameraStyle(shape: .landscape, size: CameraStyle.small, anchor: .top)] {
            #expect(try JSONDecoder().decode(CameraStyle.self, from: encoder.encode(style)) == style)
        }
    }

    private func expect(
        _ frame: CameraFrame, is rect: Rect, radius: Double, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let tolerance = 0.001
        let close = [
            (frame.rect.x, rect.x), (frame.rect.y, rect.y), (frame.rect.width, rect.width), (frame.rect.height, rect.height),
            (frame.cornerRadius, radius),
        ].allSatisfy { abs($0 - $1) <= tolerance }
        #expect(close, "\(frame) is not \(rect) with radius \(radius)", sourceLocation: sourceLocation)
    }
}
