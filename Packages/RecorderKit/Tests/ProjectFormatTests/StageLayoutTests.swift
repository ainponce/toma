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

// MARK: - The macOS window frame

@Test func barHeightRule() {
    // Without padding, a square screen in a tall output: the window spans the whole width, and its bar is 0.032 of it,
    // never less than 18 px.
    let wide = StageLayout.windowRect(contentAspect: 1, padding: 0, outputSize: [1000, 3000])
    #expect(wide.window.width == 1000 && abs(wide.barHeight - 32) < 1e-9, "\(wide)")
    let narrow = StageLayout.windowRect(contentAspect: 1, padding: 0, outputSize: [400, 3000])
    #expect(narrow.window.width == 400 && narrow.barHeight == 18, "\(narrow)")
    // Where 0.032 of the width is 18 px.
    let even = StageLayout.windowRect(contentAspect: 1, padding: 0, outputSize: [562.5, 3000])
    #expect(abs(even.barHeight - 18) < 1e-9, "\(even)")
}

@Test func macWindowFitsInsideThePadding() {
    // A 16:10 display in a 1920 × 1080 output with 153.6 px of padding: the height limits, so the window spans it.
    let output = SIMD2(1920.0, 1080.0), margin = 0.08 * 1920
    let (window, screen, bar) = StageLayout.windowRect(contentAspect: 16.0 / 10, padding: 0.08, outputSize: output)
    #expect(window.x >= margin && window.x + window.width <= output.x - margin, "\(window)")
    #expect(abs(window.y - margin) < 1e-9 && abs(window.y + window.height - (output.y - margin)) < 1e-9, "\(window)")
    #expect(abs(window.x + window.width / 2 - output.x / 2) < 1e-9, "\(window)")
    #expect(abs(bar - 0.032 * window.width) < 1e-9 && bar > 18)
    // The screen: under the bar, as wide as the window, of the content's aspect, down to the window's bottom.
    #expect(screen.x == window.x && screen.width == window.width, "\(screen)")
    #expect(screen.y == window.y + bar, "\(screen)")
    #expect(abs(screen.y + screen.height - (window.y + window.height)) < 1e-9, "\(screen)")
    #expect(abs(screen.width / screen.height - 1.6) < 1e-12, "\(screen)")

    // A small output, where the bar is 18 px: the window still spans the height inside the padding.
    let small = StageLayout.windowRect(contentAspect: 16.0 / 9, padding: 0.08, outputSize: [640, 360])
    #expect(small.barHeight == 18, "\(small)")
    #expect(abs(small.window.y - 51.2) < 1e-9 && abs(small.window.height - (360 - 2 * 51.2)) < 1e-9, "\(small)")
    #expect(abs(small.screen.width / small.screen.height - 16.0 / 9) < 1e-12, "\(small)")
    #expect(small.window.x >= 51.2 && small.window.x + small.window.width <= 640 - 51.2, "\(small)")
}

@Test func macWindowFitsInsideThePaddingInPortrait() {
    // A 16:9 display in a 1080 × 1920 output with 86.4 px of padding: the width limits, and the window is centred.
    let output = SIMD2(1080.0, 1920.0), margin = 0.08 * 1080
    let (window, screen, bar) = StageLayout.windowRect(contentAspect: 16.0 / 9, padding: 0.08, outputSize: output)
    #expect(abs(window.x - margin) < 1e-9 && abs(window.x + window.width - (output.x - margin)) < 1e-9, "\(window)")
    #expect(window.y >= margin && window.y + window.height <= output.y - margin, "\(window)")
    #expect(abs(window.y + window.height / 2 - output.y / 2) < 1e-9, "\(window)")
    #expect(abs(bar - 0.032 * window.width) < 1e-9)
    #expect(screen.x == window.x && screen.width == window.width && screen.y == window.y + bar, "\(screen)")
    #expect(abs(window.height - (bar + screen.height)) < 1e-9 && abs(screen.width / screen.height - 16.0 / 9) < 1e-12)

    // Without an aspect, the window is the whole room inside the padding, the screen all of it under the bar.
    let room = StageLayout.windowRect(contentAspect: nil, padding: 0.08, outputSize: output)
    #expect(room.window == StageLayout.screenRect(contentAspect: nil, padding: 0.08, outputSize: output), "\(room)")
    #expect(room.screen.y == room.window.y + room.barHeight && room.screen.width == room.window.width, "\(room)")
    #expect(abs(room.screen.y + room.screen.height - (room.window.y + room.window.height)) < 1e-9, "\(room)")
    // Padding that leaves no room, or none for the bar: an empty window at the centre.
    for (padding, size) in [(0.6, SIMD2(1080.0, 1920.0)), (0.0, SIMD2(1000.0, 18.0))] {
        for aspect in [nil, 16.0 / 9] {
            let empty = StageLayout.windowRect(contentAspect: aspect, padding: padding, outputSize: size)
            let centre = Rect(x: size.x / 2, y: size.y / 2, width: 0, height: 0)
            #expect(empty.window == centre && empty.screen == centre && empty.barHeight == 0, "\(empty)")
        }
    }
}
