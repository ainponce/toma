// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat
import Testing

@Test func outputSizesForEveryAspect() {
    let cases: [(aspect: Aspect, shortSide: Int, size: SIMD2<Int>)] = [
        (.landscape, 1080, [1920, 1080]), (.portrait, 1080, [1080, 1920]), (.square, 1080, [1080, 1080]),
        (.landscape, 720, [1280, 720]), (.landscape, 1440, [2560, 1440]), (.landscape, 2160, [3840, 2160]),
        (.portrait, 2160, [2160, 3840]),
    ]
    for (aspect, shortSide, size) in cases {
        #expect(StageLayout.outputSize(aspect: aspect, shortSide: shortSide) == size, "\(aspect) at \(shortSide)")
    }
}

@Test func portraitOutputFitsAWideScreen() {
    // A 16:10 display in a 1080 × 1920 output: the width limits, 86.4 px of padding on each side.
    let rect = StageLayout.screenRect(contentAspect: 16.0 / 10, padding: 0.08, outputSize: [1080, 1920])
    #expect(abs(rect.x - 86.4) < 1e-9 && abs(rect.y - 676.5) < 1e-9, "\(rect)")
    #expect(abs(rect.width - 907.2) < 1e-9 && abs(rect.height - 567) < 1e-9, "\(rect)")
}

@Test func screenRectWithoutAnAspectFillsThePaddedArea() {
    // Padding is a fraction of the width on every side, also at the top and bottom.
    let rect = StageLayout.screenRect(contentAspect: nil, padding: 0.08, outputSize: [1920, 1080])
    #expect(abs(rect.x - 153.6) < 1e-9 && abs(rect.y - 153.6) < 1e-9, "\(rect)")
    #expect(abs(rect.width - (1920 - 2 * 153.6)) < 1e-9 && abs(rect.height - (1080 - 2 * 153.6)) < 1e-9, "\(rect)")
    // Padding that leaves no room: an empty rect at the centre, whatever the aspect.
    for aspect in [nil, 16.0 / 9] {
        #expect(StageLayout.screenRect(contentAspect: aspect, padding: 0.6, outputSize: [1920, 1080]) == Rect(x: 960, y: 540, width: 0, height: 0))
    }
}
