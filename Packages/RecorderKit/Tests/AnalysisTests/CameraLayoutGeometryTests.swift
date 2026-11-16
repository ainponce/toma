// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat
import Testing

// The layouts' geometry, `cameraLayout-1` (1c design §5.2): a 16:9 screen, the padding of new projects (0.08), the style's
// corners at 0.02 of the width and a Medium circle at the bottom right measured against the short side, unless a test says
// otherwise.

private let wide = 16.0 / 9
private let newPadding = 0.08
private let corners = 0.02

private func size(_ width: Double, _ height: Double) -> SIMD2<Double> { SIMD2(width, height) }

/// The bubble a project measured against the short side shows in `output`.
private func bubble(_ output: SIMD2<Double>) -> CameraFrame {
    CameraStyle.default.frame(in: Rect(x: 0, y: 0, width: output.x, height: output.y), reference: .shortSide)
}

private func geometry(
    _ kind: LayoutKind, _ output: SIMD2<Double>, screenAspect: Double? = wide, padding: Double = newPadding,
    split: SplitLayout? = SplitLayout(), bubble frame: CameraFrame?? = .none
) -> LayoutGeometry {
    CameraLayoutGeometry.geometry(
        kind: kind, split: split, bubble: frame ?? bubble(output), output: output, padding: padding, cornerRadius: corners,
        screenAspect: screenAspect)
}

/// The useful area: the output less the padding on every side.
private func usefulArea(_ output: SIMD2<Double>, padding: Double = newPadding) -> Rect {
    StageLayout.screenRect(contentAspect: nil, padding: padding, outputSize: output)
}

/// `rect` at 90 % of its size around its centre.
private func shrunk(_ rect: Rect) -> Rect {
    Rect(x: rect.x + rect.width * 0.05, y: rect.y + rect.height * 0.05, width: rect.width * 0.9, height: rect.height * 0.9)
}

private func close(_ a: Rect, _ b: Rect, within tolerance: Double = 1e-9) -> Bool {
    abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance && abs(a.width - b.width) <= tolerance
        && abs(a.height - b.height) <= tolerance
}

private func inside(_ rect: Rect, _ outer: Rect) -> Bool {
    rect.x >= outer.x - 1e-9 && rect.y >= outer.y - 1e-9 && rect.x + rect.width <= outer.x + outer.width + 1e-9
        && rect.y + rect.height <= outer.y + outer.height + 1e-9
}

private func overlap(_ a: Rect, _ b: Rect) -> Bool {
    a.x + a.width > b.x + 1e-9 && b.x + b.width > a.x + 1e-9 && a.y + a.height > b.y + 1e-9 && b.y + b.height > a.y + 1e-9
}

/// The two cards of a split, in order along it, and the space between them.
private func gap(_ g: LayoutGeometry, _ orientation: SplitOrientation) -> Double {
    let (screen, camera) = (g.screen.rect, g.camera.rect)
    switch orientation {
    case .beside:
        let (first, second) = screen.x < camera.x ? (screen, camera) : (camera, screen)
        return second.x - (first.x + first.width)
    case .stacked:
        let (first, second) = screen.y < camera.y ? (screen, camera) : (camera, screen)
        return second.y - (first.y + first.height)
    }
}

private func expectSize(_ rect: Rect, _ width: Double, _ height: Double, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(rect.width - width) <= 1 && abs(rect.height - height) <= 1, "\(rect) is not \(width)×\(height)", sourceLocation: sourceLocation)
}

@Suite struct CameraLayoutGeometryTests {
    @Test func constantsAreTheDesigns() {
        #expect(CameraLayoutGeometry.gapFraction == 0.025)
        #expect(CameraLayoutGeometry.besideShare == 0.30...0.50)
        #expect(CameraLayoutGeometry.stackedShare == 0.30...0.60)
        #expect(CameraLayoutGeometry.cameraAspectRange == (9.0 / 16)...(16.0 / 9))
        #expect(CameraLayoutGeometry.hiddenScale == 0.9)
    }

    @Test func designTableAt1080ShortSide() {
        // Split, automatic: (output, screen card, camera card).
        let splits: [(SIMD2<Double>, (Double, Double), (Double, Double))] = [
            (size(1920, 1080), (1110, 624), (476, 624)),
            (size(1440, 1080), (828, 466), (355, 466)),
            (size(1080, 1080), (907, 510), (658, 370)),
            (size(1080, 1350), (907, 510), (907, 640)),
            (size(1080, 1440), (907, 510), (907, 730)),
            (size(1080, 1920), (907, 510), (907, 1032)),
        ]
        for (output, screen, camera) in splits {
            let g = geometry(.split, output)
            expectSize(g.screen.rect, screen.0, screen.1)
            expectSize(g.camera.rect, camera.0, camera.1)
        }
        #expect(CameraLayoutGeometry.automaticShare(output: size(1920, 1080), padding: newPadding, screenAspect: wide) == 0.30)
        #expect(CameraLayoutGeometry.automaticShare(output: size(1080, 1920), padding: newPadding, screenAspect: wide) == 0.60)
        // Camera only.
        let cameraOnly: [(SIMD2<Double>, (Double, Double))] = [
            (size(1920, 1080), (1374, 773)), (size(1440, 1080), (1210, 850)), (size(1080, 1080), (907, 907)),
            (size(1080, 1350), (907, 1177)), (size(1080, 1440), (907, 1267)), (size(1080, 1920), (907, 1613)),
        ]
        for (output, camera) in cameraOnly {
            expectSize(geometry(.cameraOnly, output).camera.rect, camera.0, camera.1)
        }
    }

    @Test func everyLayoutFitsEveryFormat() {
        let outputs = [
            size(1920, 1080), size(1080, 1920), size(1080, 1080), size(1080, 1350), size(1440, 1080), size(1080, 1440),
            size(1512, 982),
        ]
        // A 16:9, 16:10 and 4:3 screen, a vertical window and a square area.
        let screens = [16.0 / 9, 16.0 / 10, 4.0 / 3, 9.0 / 16, 1]
        let splits = [
            SplitLayout(side: .end), SplitLayout(side: .start), SplitLayout(side: .end, share: 0.25),
            SplitLayout(side: .start, share: 0.60),
        ]
        let aspects = CameraLayoutGeometry.cameraAspectRange
        for output in outputs {
            let whole = Rect(x: 0, y: 0, width: output.x, height: output.y)
            let orientation = CameraLayoutGeometry.orientation(output: output)
            for screenAspect in screens {
                for padding in [0, newPadding, 0.2] {
                    let area = usefulArea(output, padding: padding)
                    for kind in LayoutKind.allCases {
                        for split in kind == .split ? splits : [SplitLayout()] {
                            let g = geometry(kind, output, screenAspect: screenAspect, padding: padding, split: split)
                            let label = "\(kind) \(split) in \(output.x)×\(output.y), screen \(screenAspect), padding \(padding)"
                            #expect(inside(g.screen.rect, whole) && inside(g.camera.rect, whole), "\(label): \(g)")
                            #expect(abs(g.screen.rect.width / g.screen.rect.height - screenAspect) <= 1e-9, "\(label): \(g.screen)")
                            switch kind {
                            case .bubble, .screenOnly:
                                #expect(inside(g.screen.rect, area), "\(label): \(g.screen)")
                            case .split:
                                #expect(inside(g.screen.rect, area) && inside(g.camera.rect, area), "\(label): \(g)")
                                #expect(abs(gap(g, orientation) - 0.025 * min(output.x, output.y)) <= 1e-9, "\(label): \(g)")
                                #expect(!overlap(g.screen.rect, g.camera.rect), "\(label): \(g)")
                            case .cameraOnly:
                                #expect(inside(g.camera.rect, area), "\(label): \(g.camera)")
                            case .cameraFull:
                                #expect(g.camera.rect == whole)
                            }
                            if kind == .split || kind == .cameraOnly {
                                let aspect = g.camera.rect.width / g.camera.rect.height
                                #expect(aspect >= aspects.lowerBound - 1e-9 && aspect <= aspects.upperBound + 1e-9, "\(label): \(g.camera)")
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func orientationComesFromTheFormat() {
        #expect(CameraLayoutGeometry.orientation(output: size(1080, 1080)) == .stacked)
        #expect(CameraLayoutGeometry.orientation(output: size(1081, 1080)) == .beside)
        #expect(CameraLayoutGeometry.orientation(output: size(1080, 1081)) == .stacked)
    }

    @Test func macBookScreenSplitIn169() {
        expectSize(geometry(.split, size(1920, 1080), screenAspect: 16.0 / 10).camera.rect, 476, 694)
    }

    @Test func verticalWindowHitsTheCapAndCenters() {
        let output = size(1920, 1080), window = 9.0 / 16
        #expect(CameraLayoutGeometry.automaticShare(output: output, padding: newPadding, screenAspect: window) == 0.50)
        let g = geometry(.split, output, screenAspect: window), area = usefulArea(output)
        let (screen, camera) = (g.screen.rect, g.camera.rect)
        let left = min(screen.x, camera.x), right = max(screen.x + screen.width, camera.x + camera.width)
        let top = min(screen.y, camera.y), bottom = max(screen.y + screen.height, camera.y + camera.height)
        #expect(abs((left - area.x) - (area.x + area.width - right)) <= 1e-9, "\(g)")
        #expect(abs((top - area.y) - (area.y + area.height - bottom)) <= 1e-9, "\(g)")
        // The camera takes half of the length along the split: (1612.8 − 27) / 2.
        #expect(abs(camera.width - (1612.8 - 27) / 2) <= 1e-9, "\(g)")
    }

    @Test func sideStartPutsTheCameraFirst() {
        let beside = size(1920, 1080), stacked = size(1080, 1920)
        let left = geometry(.split, beside, split: SplitLayout(side: .start))
        #expect(left.camera.rect.x + left.camera.rect.width < left.screen.rect.x, "\(left)")
        let right = geometry(.split, beside, split: SplitLayout(side: .end))
        #expect(right.screen.rect.x + right.screen.rect.width < right.camera.rect.x, "\(right)")
        let above = geometry(.split, stacked, split: SplitLayout(side: .start))
        #expect(above.camera.rect.y + above.camera.rect.height < above.screen.rect.y, "\(above)")
        let below = geometry(.split, stacked, split: SplitLayout(side: .end))
        #expect(below.screen.rect.y + below.screen.rect.height < below.camera.rect.y, "\(below)")
        // Without settings, a split is the default one: the camera second.
        #expect(geometry(.split, beside, split: nil) == right)
    }

    @Test func hiddenPartsStayWhereBubbleHasThemAt90Percent() {
        for output in [size(1920, 1080), size(1080, 1920), size(1080, 1350)] {
            let frame = bubble(output)
            let stage = StageLayout.screenRect(contentAspect: wide, padding: newPadding, outputSize: output)
            let shown = geometry(.bubble, output)
            #expect(shown.screen == ScreenCard(rect: stage, cornerRadius: corners * output.x, opacity: 1))
            #expect(shown.camera == CameraCard(rect: frame.rect, cornerRadius: frame.cornerRadius, opacity: 1, borderWeight: 1, shadowWeight: 1))
            // The camera a layout does not show.
            let screenOnly = geometry(.screenOnly, output)
            #expect(screenOnly.screen == shown.screen)
            #expect(close(screenOnly.camera.rect, shrunk(frame.rect)), "\(screenOnly.camera)")
            #expect(abs(screenOnly.camera.cornerRadius - 0.9 * frame.cornerRadius) <= 1e-9)
            #expect(screenOnly.camera.opacity == 0)
            // The screen a layout does not show.
            for kind in [LayoutKind.cameraOnly, .cameraFull] {
                let g = geometry(kind, output)
                #expect(close(g.screen.rect, shrunk(stage)), "\(kind): \(g.screen)")
                #expect(abs(g.screen.cornerRadius - 0.9 * corners * output.x) <= 1e-9)
                #expect(g.screen.opacity == 0)
                #expect(g.camera.opacity == 1)
            }
        }
    }

    @Test func cameraFullCoversTheOutput() {
        for output in [size(1920, 1080), size(1080, 1920), size(1512, 982)] {
            let camera = geometry(.cameraFull, output).camera
            #expect(camera == CameraCard(rect: Rect(x: 0, y: 0, width: output.x, height: output.y), cornerRadius: 0, opacity: 1, borderWeight: 0, shadowWeight: 0))
        }
    }

    @Test func splitIsCardMode() {
        // The zoom moves the whole stage only while the screen is shown on it; a split zooms inside its card, and the two
        // camera layouts keep the background still (1c design §5.4).
        for kind in LayoutKind.allCases {
            let expected: ScreenMode = kind == .bubble || kind == .screenOnly ? .stage : .card
            #expect(geometry(kind, size(1920, 1080)).mode == expected, "\(kind)")
        }
    }

    @Test func cameraLayoutsKeepTheBackgroundStillInEveryFormat() {
        let outputs = [
            size(1920, 1080), size(1080, 1920), size(1080, 1080), size(1080, 1350), size(1440, 1080), size(1080, 1440),
            size(1512, 982),
        ]
        for output in outputs {
            for screenAspect in [16.0 / 9, 16.0 / 10, 4.0 / 3, 9.0 / 16, 1, nil] {
                for padding in [0, newPadding, 0.2] {
                    for kind in [LayoutKind.cameraOnly, .cameraFull] {
                        for frame in [bubble(output), nil] {
                            let g = geometry(kind, output, screenAspect: screenAspect, padding: padding, bubble: .some(frame))
                            #expect(g.mode == .card, "\(kind) in \(output.x)×\(output.y), screen \(String(describing: screenAspect))")
                        }
                    }
                }
            }
        }
    }

    @Test func cardsHaveTheStylesCornersAndTheCameraItsBorderAndShadow() {
        let output = size(1080, 1350)
        for kind in [LayoutKind.split, .cameraOnly] {
            let g = geometry(kind, output)
            #expect(g.camera.cornerRadius == corners * 1080 && g.camera.opacity == 1, "\(kind)")
            #expect(g.camera.borderWeight == 1 && g.camera.shadowWeight == 1, "\(kind)")
        }
        let split = geometry(.split, output)
        #expect(split.screen == ScreenCard(rect: split.screen.rect, cornerRadius: corners * 1080, opacity: 1))
    }

    @Test func aBlocksShareIsUsedWithinItsRange() {
        let output = size(1920, 1080), area = usefulArea(output)
        let length = area.width - 0.025 * 1080
        let g = geometry(.split, output, split: SplitLayout(share: 0.45))
        #expect(abs(g.camera.rect.width - 0.45 * length) <= 1e-9, "\(g)")
        // The screen gets the rest: 0.55 of the length, at 16:9.
        #expect(abs(g.screen.rect.width - 0.55 * length) <= 1e-9, "\(g)")
        // One outside `SplitLayout.shareRange` is taken to its nearest end.
        #expect(geometry(.split, output, split: SplitLayout(share: 0.9)) == geometry(.split, output, split: SplitLayout(share: 0.60)))
        #expect(geometry(.split, output, split: SplitLayout(share: 0.1)) == geometry(.split, output, split: SplitLayout(share: 0.25)))
    }

    @Test func withoutABubbleTheCameraWaitsAtTheCentreOfTheOutput() {
        let output = size(1920, 1080), centre = Rect(x: 960, y: 540, width: 0, height: 0)
        for kind in [LayoutKind.bubble, .screenOnly] {
            let camera = geometry(kind, output, bubble: .some(nil)).camera
            #expect(camera.rect == centre && camera.opacity == 0, "\(kind): \(camera)")
        }
        // The layouts that show the camera in a card of their own do not need the bubble: before the camera's first
        // frame, Camera only and Camera full screen show that frame (1c design §5.1).
        for kind in [LayoutKind.split, .cameraOnly, .cameraFull] {
            #expect(geometry(kind, output, bubble: .some(nil)) == geometry(kind, output), "\(kind)")
        }
    }

    @Test func withoutTheScreensAspectTheScreenTakesItsWholeBox() {
        // As `StageLayout.screenRect` does without an aspect: the screen's card is all its box, and the camera gets the
        // smallest automatic part.
        let output = size(1920, 1080), area = usefulArea(output)
        let length = area.width - 27
        let g = geometry(.split, output, screenAspect: nil)
        #expect(abs(g.screen.rect.width - 0.70 * length) <= 1e-9 && abs(g.screen.rect.height - area.height) <= 1e-9, "\(g)")
        #expect(abs(g.camera.rect.width - 0.30 * length) <= 1e-9 && abs(g.camera.rect.height - area.height) <= 1e-9, "\(g)")
        let hidden = geometry(.cameraOnly, output, screenAspect: nil).screen
        #expect(close(hidden.rect, shrunk(area)) && hidden.opacity == 0, "\(hidden)")
    }

    @Test func noRoomLeavesEmptyCardsAndNoNaN() {
        for output in [size(1920, 1080), size(1080, 1920)] {
            for padding in [0.5, 0.75] {
                for kind in LayoutKind.allCases {
                    let g = geometry(kind, output, padding: padding)
                    let numbers = [
                        g.screen.rect.x, g.screen.rect.y, g.screen.rect.width, g.screen.rect.height, g.screen.cornerRadius,
                        g.camera.rect.x, g.camera.rect.y, g.camera.rect.width, g.camera.rect.height, g.camera.cornerRadius,
                    ]
                    let finite = numbers.allSatisfy { $0.isFinite }
                    #expect(finite, "\(kind) with padding \(padding): \(g)")
                    if kind == .split || kind == .cameraOnly {
                        #expect(g.camera.rect.width == 0 || g.camera.rect.height == 0, "\(kind): \(g.camera)")
                    }
                }
            }
        }
    }

    @Test func mixIsLinearInEveryNumber() {
        let output = size(1920, 1080)
        let a = geometry(.bubble, output), b = geometry(.split, output)
        // Exactly each end at 0 and 1, as `CameraStyleTimeline` blends.
        #expect(LayoutGeometry.mix(a, b, 0) == a)
        #expect(LayoutGeometry.mix(a, b, 1) == b)
        let quarter = LayoutGeometry.mix(a, b, 0.25)
        func at(_ x: Double, _ y: Double) -> Double { x + (y - x) * 0.25 }
        let pairs: [(Double, Double, Double)] = [
            (quarter.screen.rect.x, a.screen.rect.x, b.screen.rect.x),
            (quarter.screen.rect.y, a.screen.rect.y, b.screen.rect.y),
            (quarter.screen.rect.width, a.screen.rect.width, b.screen.rect.width),
            (quarter.screen.rect.height, a.screen.rect.height, b.screen.rect.height),
            (quarter.screen.cornerRadius, a.screen.cornerRadius, b.screen.cornerRadius),
            (quarter.camera.rect.x, a.camera.rect.x, b.camera.rect.x),
            (quarter.camera.rect.y, a.camera.rect.y, b.camera.rect.y),
            (quarter.camera.rect.width, a.camera.rect.width, b.camera.rect.width),
            (quarter.camera.rect.height, a.camera.rect.height, b.camera.rect.height),
            (quarter.camera.cornerRadius, a.camera.cornerRadius, b.camera.cornerRadius),
        ]
        for (mixed, x, y) in pairs { #expect(abs(mixed - at(x, y)) <= 1e-9) }
        // Opacities and weights between a layout that shows the screen and one that hides it, and Camera full screen.
        let full = geometry(.cameraFull, output)
        let half = LayoutGeometry.mix(a, full, 0.5)
        #expect(half.screen.opacity == 0.5 && half.camera.opacity == 1)
        #expect(half.camera.borderWeight == 0.5 && half.camera.shadowWeight == 0.5)
        // The mode is the new layout's as soon as the blend starts.
        #expect(LayoutGeometry.mix(a, b, 0.001).mode == .card)
        #expect(LayoutGeometry.mix(b, a, 0.001).mode == .stage)
    }
}
