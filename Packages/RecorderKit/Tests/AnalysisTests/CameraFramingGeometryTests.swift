// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat
import Testing

// The camera's crop (phase 2 design §6.2, plan 2b decision 2): the part of a 1280 × 720 frame that fills the camera's
// shape, divided by the zoom and kept in the frame, in fractions of the frame.

private let frame = SIMD2<Double>(1280, 720)
private let middle = SIMD2<Double>(0.5, 0.5)
/// A circle (or any square shape), a 9:16 card and a 16:9 card.
private let aspects = [1.0, 9.0 / 16, 16.0 / 9]

/// `Compositor.aspectFill(_:in:)` (Render) written again, apart from the code under test: all of the image along the axis
/// where its shape is narrower than the rect's, the middle of it along the other.
private func aspectFill(_ size: SIMD2<Double>, rectAspect: Double) -> Rect {
    let imageAspect = size.x / size.y
    if imageAspect > rectAspect {
        let width = rectAspect / imageAspect
        return Rect(x: (1 - width) / 2, y: 0, width: width, height: 1)
    }
    let height = imageAspect / rectAspect
    return Rect(x: 0, y: (1 - height) / 2, width: 1, height: height)
}

private func crop(_ aspect: Double, center: SIMD2<Double> = middle, zoom: Double) -> Rect {
    CameraFramingGeometry.crop(frameSize: frame, rectAspect: aspect, center: center, zoom: zoom)
}

private func close(_ a: Rect, _ b: Rect, within tolerance: Double = 1e-12) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance && abs(a.width - b.width) <= tolerance
        && abs(a.height - b.height) <= tolerance
}

@Test func centeredAtZoomOneIsTheAspectFill() {
    for aspect in aspects {
        // The same numbers as the compositor's fill, bit for bit, also once made `Float` as the compositor hands them over.
        let made = crop(aspect, zoom: 1), fill = aspectFill(frame, rectAspect: aspect)
        #expect(made == fill)
        #expect(Float(made.x) == Float(fill.x) && Float(made.width) == Float(fill.width))
    }
    #expect(close(crop(1, zoom: 1), Rect(x: 0.21875, y: 0, width: 0.5625, height: 1)))
    #expect(close(crop(9.0 / 16, zoom: 1), Rect(x: 0.341796875, y: 0, width: 0.31640625, height: 1)))
    #expect(crop(16.0 / 9, zoom: 1) == Rect(x: 0, y: 0, width: 1, height: 1))
    // A shape wider than the frame takes all its width and the middle of its height.
    #expect(close(crop(2, zoom: 1), Rect(x: 0, y: 0.0555555555555556, width: 1, height: 0.888888888888889)))
}

@Test func zoomDividesTheFill() {
    for aspect in aspects {
        let fill = aspectFill(frame, rectAspect: aspect), zoomed = crop(aspect, zoom: 2)
        #expect(zoomed.width == fill.width / 2 && zoomed.height == fill.height / 2)
        // Centred.
        #expect(abs(zoomed.x + zoomed.width / 2 - 0.5) <= 1e-15 && abs(zoomed.y + zoomed.height / 2 - 0.5) <= 1e-15)
    }
    #expect(close(crop(1, zoom: 2), Rect(x: 0.359375, y: 0.25, width: 0.28125, height: 0.5)))
}

@Test func neverLeavesTheFrame() {
    for aspect in aspects {
        let fill = aspectFill(frame, rectAspect: aspect)
        let top = crop(aspect, center: SIMD2(0, 0), zoom: 1.4), bottom = crop(aspect, center: SIMD2(1, 1), zoom: 1.4)
        #expect(top.x == 0 && top.y == 0)
        #expect(bottom.x + bottom.width == 1 && bottom.y + bottom.height == 1)
        for part in [top, bottom] {
            #expect(part.width == fill.width / 1.4 && part.height == fill.height / 1.4)
            #expect(part.x >= 0 && part.y >= 0 && part.x + part.width <= 1 && part.y + part.height <= 1)
        }
        // Far outside, the same as at the edge.
        #expect(crop(aspect, center: SIMD2(-3, 9), zoom: 1.4) == crop(aspect, center: SIMD2(0, 1), zoom: 1.4))
    }
    // Inside, where it can be, the crop is centred on the centre.
    let near = crop(1, center: SIMD2(0.3, 0.6), zoom: 2.5)
    #expect(abs(near.x + near.width / 2 - 0.3) <= 1e-15 && abs(near.y + near.height / 2 - 0.6) <= 1e-15)
}

@Test func zoomIsReadFrom1To2_5() {
    for aspect in aspects {
        #expect(crop(aspect, zoom: 0.5) == crop(aspect, zoom: 1))
        #expect(crop(aspect, zoom: 9) == crop(aspect, zoom: 2.5))
        #expect(crop(aspect, zoom: .nan) == crop(aspect, zoom: 1))
        #expect(crop(aspect, zoom: .infinity) == crop(aspect, zoom: 2.5))
        #expect(crop(aspect, zoom: -.infinity) == crop(aspect, zoom: 1))
    }
    #expect(CameraFramingGeometry.clampedZoom(0.5) == 1)
    #expect(CameraFramingGeometry.clampedZoom(1.4) == 1.4)
    #expect(CameraFramingGeometry.clampedZoom(9) == 2.5)
    #expect(CameraFramingGeometry.clampedZoom(.nan) == 1)
}

@Test func whatIsNotANumberIsTheMiddleOrTheWholeFrame() {
    // A centre that is not a number is the middle.
    #expect(crop(1, center: SIMD2(.nan, .nan), zoom: 1.4) == crop(1, zoom: 1.4))
    #expect(crop(1, center: SIMD2(.nan, 0.5), zoom: 1) == crop(1, zoom: 1))
    // A frame or a shape without a size (as `Compositor.aspectFill`): the whole frame, then the zoom.
    for (size, aspect) in [(SIMD2<Double>(0, 720), 1.0), (frame, 0), (frame, .nan), (frame, .infinity), (SIMD2(.nan, 720), 1)] {
        #expect(CameraFramingGeometry.crop(frameSize: size, rectAspect: aspect, center: middle, zoom: 1)
            == Rect(x: 0, y: 0, width: 1, height: 1))
        #expect(CameraFramingGeometry.crop(frameSize: size, rectAspect: aspect, center: middle, zoom: 2)
            == Rect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    }
}
