// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import CoreGraphics
import Foundation
import ProjectFormat
import Testing

@Suite struct CameraBubbleLayoutTests {
    /// The prototype's screen: 1200 × 750 points.
    private static let reference = Rect(x: 0, y: 0, width: 1200, height: 750)

    @Test func projectionUsesTheDecelerationRate() {
        #expect(Momentum.decelerationRate == 0.992)
        #expect(abs(Momentum.project(velocity: 1000) - 124) < 0.001)
        #expect(abs(Momentum.project(velocity: -500) - -62) < 0.001)
        #expect(Momentum.project(velocity: 0) == 0)
        // A lower rate stops sooner.
        #expect(Momentum.project(velocity: 1000, decelerationRate: 0.99) < Momentum.project(velocity: 1000))
    }

    @Test func releaseSnapsToTheNearestProjectedAnchor() {
        let style = CameraStyle.default
        // Still: the nearest place to where it was let go.
        let still = CameraBubbleLayout.releaseAnchor(origin: CGPoint(x: 900, y: 100), velocity: .zero, style: style, region: Self.reference)
        #expect(still == .topTrailing)
        // Thrown to the left at 3000 pt/s: it would travel 372 pt, past the middle.
        let thrown = CameraBubbleLayout.releaseAnchor(
            origin: CGPoint(x: 900, y: 100), velocity: CGVector(dx: -3000, dy: 0), style: style, region: Self.reference)
        #expect(thrown == .top)
        // Thrown down from the top left: the bottom left, on the other axis.
        let down = CameraBubbleLayout.releaseAnchor(
            origin: CGPoint(x: 30, y: 30), velocity: CGVector(dx: 0, dy: 5000), style: style, region: Self.reference)
        #expect(down == .bottomLeading)
        // Thrown far past an edge, it stays at that edge.
        let far = CameraBubbleLayout.releaseAnchor(
            origin: CGPoint(x: 500, y: 300), velocity: CGVector(dx: 40_000, dy: 40_000), style: style, region: Self.reference)
        #expect(far == .bottomTrailing)
    }

    @Test func anchorFramesAreTheEightPlaces() {
        let style = CameraStyle(shape: .landscape, size: CameraStyle.small, anchor: .top)
        let places = CameraBubbleLayout.anchorFrames(style: style, region: Self.reference)
        #expect(places.map(\.anchor) == CameraAnchor.allCases)
        #expect(Set(places.map(\.anchor)).count == 8)
        // Every place has the style's box, where `frame` puts it for that anchor.
        for place in places {
            var anchored = style
            anchored.anchor = place.anchor
            #expect(place.rect == anchored.frame(in: Self.reference).rect)
        }
        // None is in the middle of both axes.
        let circle = CameraBubbleLayout.anchorFrames(style: .default, region: Self.reference)
        let center = (x: (1200 - 180) / 2.0, y: (750 - 180) / 2.0)
        #expect(!circle.contains { $0.rect.x == center.x && $0.rect.y == center.y })
        #expect(circle.first { $0.anchor == .topLeading }?.rect == Rect(x: 24, y: 24, width: 180, height: 180))
    }

    @Test func bubbleRegionIsTheChosenDisplayUnderThePointer() {
        let displays = [
            DisplayInfo(id: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982), scale: 2, isMain: true, maximumFramesPerSecond: 120),
            DisplayInfo(id: 2, frame: Rect(x: -1920, y: -200, width: 1920, height: 1080), scale: 1, isMain: false, maximumFramesPerSecond: 60),
        ]
        var both = CaptureSelection(mode: .display, displayIDs: [1, 2], camera: .systemDefault, microphone: .off, systemAudio: .off)
        func region(_ selection: CaptureSelection, pointer: CGPoint?, window: Rect? = nil) -> Rect? {
            CameraBubbleLayout.region(for: selection, displays: displays, pointer: pointer, windowFrame: window)
        }
        #expect(region(both, pointer: CGPoint(x: -960, y: 340)) == displays[1].frame)
        #expect(region(both, pointer: CGPoint(x: 700, y: 20)) == displays[0].frame)
        // Off both, or not known: the first one chosen.
        #expect(region(both, pointer: CGPoint(x: 5000, y: 5000)) == displays[0].frame)
        #expect(region(both, pointer: nil) == displays[0].frame)
        both.displayIDs = [2, 1]
        #expect(region(both, pointer: CGPoint(x: 5000, y: 5000)) == displays[1].frame)
        // Only the chosen displays: the pointer over another one does not count.
        let one = CaptureSelection.mainDisplay(2)
        #expect(region(one, pointer: CGPoint(x: 700, y: 20)) == displays[1].frame)
        // A display no longer connected is skipped.
        #expect(region(CaptureSelection.mainDisplay(9), pointer: nil) == nil)

        let rect = Rect(x: 100, y: 120, width: 640, height: 360)
        let area = CaptureSelection(
            mode: .area, displayIDs: [1], area: AreaChoice(displayID: 1, rect: rect), camera: .systemDefault, microphone: .off,
            systemAudio: .off)
        #expect(region(area, pointer: CGPoint(x: -960, y: 340)) == rect)
        let window = Rect(x: 40, y: 60, width: 800, height: 500)
        let windowSelection = CaptureSelection(mode: .window, displayIDs: [1], windowID: 7, camera: .systemDefault, microphone: .off, systemAudio: .off)
        #expect(region(windowSelection, pointer: nil, window: window) == window)
        #expect(region(windowSelection, pointer: nil) == nil)

        var none = both
        none.displayIDs = []
        #expect(region(none, pointer: CGPoint(x: 700, y: 20)) == nil)
    }

    @Test func bubbleShowsOnlyWhileTheIslandIsInUse() {
        let shown: [IslandState] = [.open, .choosing, .countdown(remaining: 3), .recording, .recordingOpen, .notice(.microphoneSilent)]
        let hidden: [IslandState] = [
            .rest, .peek, .saving,
            .saved(SavedTake(
                projectURL: URL(fileURLWithPath: "/tmp/Recording.toma"), duration: .seconds(5), markers: 0, trackKinds: [.display],
                openedEditor: false)),
        ]
        for state in shown + hidden {
            #expect(!CameraBubbleLayout.isVisible(cameraOn: false, island: state))
        }
        for state in shown {
            #expect(CameraBubbleLayout.isVisible(cameraOn: true, island: state))
        }
        for state in hidden {
            #expect(!CameraBubbleLayout.isVisible(cameraOn: true, island: state))
        }
    }

    @Test func releaseVelocityIsTheLastTenthOfASecond() {
        func sample(_ time: Double, _ x: Double, _ y: Double) -> CameraBubbleLayout.DragSample {
            CameraBubbleLayout.DragSample(time: time, point: CGPoint(x: x, y: y))
        }
        // Steady at 1000 pt/s to the right and 500 pt/s down, sampled every 10 ms.
        let steady = (0...20).map { sample(Double($0) * 0.01, Double($0) * 10, Double($0) * 5) }
        let velocity = CameraBubbleLayout.releaseVelocity(samples: steady, at: 0.2)
        #expect(abs(velocity.dx - 1000) < 0.001 && abs(velocity.dy - 500) < 0.001)
        // Only the last 100 ms count: a fast start does not.
        let slowed = [sample(0, 0, 0), sample(0.05, 400, 0), sample(0.15, 410, 0), sample(0.25, 420, 0)]
        #expect(abs(CameraBubbleLayout.releaseVelocity(samples: slowed, at: 0.25).dx - 100) < 0.001)
        // Held still before letting go: no velocity.
        let held = [sample(0, 0, 0), sample(0.05, 300, 0), sample(0.30, 300, 0)]
        #expect(CameraBubbleLayout.releaseVelocity(samples: held, at: 0.32) == .zero)
        // Not moved at all, or one sample.
        #expect(CameraBubbleLayout.releaseVelocity(samples: [sample(1, 5, 5)], at: 1) == .zero)
        #expect(CameraBubbleLayout.releaseVelocity(samples: [], at: 1) == .zero)
    }
}
