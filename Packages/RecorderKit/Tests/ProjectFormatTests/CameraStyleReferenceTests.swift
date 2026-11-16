// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat
import Testing

// The bubble measured against the output's height (1a and 1b) or its short side (new projects from 1c on): 1c design
// §5.2.

@Suite struct CameraStyleReferenceTests {
    private static let wide = Rect(x: 0, y: 0, width: 1920, height: 1080)
    private static let tall = Rect(x: 0, y: 0, width: 1080, height: 1920)

    @Test func heightReferenceIsTodaysFrame() {
        for region in [Self.wide, Self.tall] {
            for shape in CameraShape.allCases {
                for size in [CameraStyle.small, CameraStyle.medium, CameraStyle.large] {
                    for anchor in CameraAnchor.allCases {
                        let style = CameraStyle(shape: shape, size: size, anchor: anchor)
                        #expect(bits(style.frame(in: region, reference: .height)) == bits(style.frame(in: region)), "\(style)")
                    }
                }
            }
        }
    }

    @Test func shortSideBubbleIsTheSameSizeInEveryFormat() {
        for (width, height) in [(1920.0, 1080.0), (1080, 1920), (1080, 1350)] {
            let frame = CameraStyle.default.frame(in: Rect(x: 0, y: 0, width: width, height: height), reference: .shortSide)
            #expect(frame.rect.width.rounded() == 259 && frame.rect.height.rounded() == 259, "\(width)×\(height): \(frame)")
        }
        #expect(CameraStyle.default.frame(in: Self.tall, reference: .height).rect.width.rounded() == 461)
    }

    @Test func shortSideMeasuresTheMarginAndTheCornersToo() {
        // 1080 × 1920: the short side is 1080, so the margin is 0.032 × 1080 and the boxes' corners 20 and 18 of 750 of it.
        let margin = 0.032 * 1080
        let circle = CameraStyle.default.frame(in: Self.tall, reference: .shortSide)
        expect(circle, is: Rect(x: 1080 - 259.2 - margin, y: 1920 - 259.2 - margin, width: 259.2, height: 259.2), radius: 129.6)
        let portrait = CameraStyle(shape: .portrait, size: CameraStyle.medium, anchor: .topLeading).frame(in: Self.tall, reference: .shortSide)
        expect(portrait, is: Rect(x: margin, y: margin, width: 259.2 * (0.75).squareRoot(), height: 259.2 / (0.75).squareRoot()), radius: 28.8)
        let landscape = CameraStyle(shape: .landscape, size: CameraStyle.small, anchor: .leading).frame(in: Self.tall, reference: .shortSide)
        let side = 0.17 * 1080, root = (16.0 / 9).squareRoot()
        expect(landscape, is: Rect(x: margin, y: (1920 - side / root) / 2, width: side * root, height: side / root), radius: 25.92)
        // A region away from the origin is moved by it, as `frame(in:)` does.
        let moved = CameraStyle.default.frame(in: Rect(x: -1080, y: 200, width: 1080, height: 1920), reference: .shortSide)
        expect(moved, is: Rect(x: -1080 + 1080 - 259.2 - margin, y: 200 + 1920 - 259.2 - margin, width: 259.2, height: 259.2), radius: 129.6)
    }

    @Test func wideAndSquareFormatsGiveTheSameWithBothReferences() {
        for region in [Self.wide, Rect(x: 0, y: 0, width: 1440, height: 1080), Rect(x: 0, y: 0, width: 1080, height: 1080)] {
            for shape in CameraShape.allCases {
                for anchor in CameraAnchor.allCases {
                    let style = CameraStyle(shape: shape, size: CameraStyle.large, anchor: anchor)
                    #expect(bits(style.frame(in: region, reference: .shortSide)) == bits(style.frame(in: region)), "\(style)")
                }
            }
        }
    }

    /// Every number of a frame, as its bits.
    private func bits(_ frame: CameraFrame) -> [UInt64] {
        [frame.rect.x, frame.rect.y, frame.rect.width, frame.rect.height, frame.cornerRadius].map(\.bitPattern)
    }

    private func expect(_ frame: CameraFrame, is rect: Rect, radius: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        let close = [
            (frame.rect.x, rect.x), (frame.rect.y, rect.y), (frame.rect.width, rect.width), (frame.rect.height, rect.height),
            (frame.cornerRadius, radius),
        ].allSatisfy { abs($0 - $1) <= 1e-9 }
        #expect(close, "\(frame) is not \(rect) with radius \(radius)", sourceLocation: sourceLocation)
    }
}
