// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import CoreGraphics
import Foundation
import Testing

@Suite struct IslandGeometryTests {
    /// A 14-inch MacBook Pro at its default resolution: the notch is 188 × 32 pt.
    private static let notchScreen = ScreenTop.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 662, height: 32),
        auxiliaryTopRight: CGRect(x: 850, y: 950, width: 662, height: 32),
        menuBarHeight: 24)
    /// An external display to the right of it.
    private static let externalScreen = ScreenTop.make(
        frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), safeAreaTop: 0,
        auxiliaryTopLeft: nil, auxiliaryTopRight: nil, menuBarHeight: 24)

    @Test func notchScreenUsesTheNotchWidthAndMenuBarHeight() {
        let top = Self.notchScreen
        #expect(top.notch == CGRect(x: 662, y: 950, width: 188, height: 32))
        #expect(top.menuBarHeight == 32)
        #expect(IslandGeometry.shape(.rest, on: top) == IslandShape(width: 188, height: 32, bottomRadius: 13, roundsTopCorners: false))
        #expect(IslandGeometry.shape(.peek, on: top) == IslandShape(width: 252, height: 68, bottomRadius: 18, roundsTopCorners: false))
        // A narrow notch still gives the peek's row its room.
        let narrow = ScreenTop(frame: top.frame, notch: CGRect(x: 700, y: 950, width: 120, height: 32), menuBarHeight: 32)
        #expect(IslandGeometry.shape(.peek, on: narrow).width == IslandGeometry.peekMinWidth)
        // Peeking from the Replay's wings never narrows the island.
        let wings = IslandGeometry.shape(.rest, on: top, replaying: true).width
        #expect(IslandGeometry.shape(.peek, on: top, replaying: true).width == wings)
        #expect(IslandGeometry.shape(.peek, on: top, replaying: false).width == 252)
        #expect(IslandGeometry.shape(.open, on: top) == IslandShape(width: 700, height: 400, bottomRadius: 34, roundsTopCorners: false))
        #expect(IslandGeometry.shape(.choosing, on: top) == IslandShape(width: 560, height: 48, bottomRadius: 24, roundsTopCorners: false))
        #expect(IslandGeometry.frame(IslandGeometry.shape(.open, on: top), on: top) == CGRect(x: 406, y: 582, width: 700, height: 400))
        #expect(IslandGeometry.frame(IslandGeometry.shape(.rest, on: top), on: top) == top.notch)
        #expect(IslandGeometry.hoverZone(on: top) == top.notch)
    }

    @Test func aScreenWithoutBothSideAreasHasNoNotch() {
        let top = ScreenTop.make(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
            auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 662, height: 32), auxiliaryTopRight: nil, menuBarHeight: 24)
        #expect(top.notch == nil && top.menuBarHeight == 24)
    }

    @Test func screenWithoutNotchGetsAPillBelowTheTop() {
        let top = Self.externalScreen
        #expect(top.notch == nil && top.menuBarHeight == 24)
        #expect(IslandGeometry.shape(.rest, on: top) == IslandShape(width: 132, height: 34, bottomRadius: 17, roundsTopCorners: true))
        #expect(IslandGeometry.shape(.peek, on: top) == IslandShape(width: 262, height: 38, bottomRadius: 19, roundsTopCorners: true))
        #expect(IslandGeometry.shape(.open, on: top) == IslandShape(width: 700, height: 400, bottomRadius: 38, roundsTopCorners: true))
        #expect(IslandGeometry.shape(.choosing, on: top) == IslandShape(width: 560, height: 48, bottomRadius: 24, roundsTopCorners: true))
        #expect(IslandGeometry.frame(IslandGeometry.shape(.rest, on: top), on: top) == CGRect(x: 2406, y: 1008, width: 132, height: 34))
        #expect(IslandGeometry.hoverZone(on: top) == CGRect(x: 2442, y: 1072, width: 60, height: 8))
    }

    @Test func recordingShapesFollowTheDesignTable() {
        let top = Self.notchScreen
        #expect(IslandGeometry.shape(.countdown(remaining: 3), on: top) == IslandShape(width: 236, height: 214, bottomRadius: 62, roundsTopCorners: false))
        #expect(IslandGeometry.shape(.countdown(remaining: 1), on: top) == IslandGeometry.shape(.countdown(remaining: 3), on: top))
        #expect(IslandGeometry.shape(.recording, on: top) == IslandShape(width: 356, height: 32, bottomRadius: 13, roundsTopCorners: false))
        #expect(IslandGeometry.shape(.recordingOpen, on: top) == IslandShape(width: 640, height: 226, bottomRadius: 34, roundsTopCorners: false))

        let external = Self.externalScreen
        #expect(IslandGeometry.shape(.recording, on: external) == IslandShape(width: 300, height: 36, bottomRadius: 17, roundsTopCorners: true))
        #expect(IslandGeometry.shape(.countdown(remaining: 3), on: external) == IslandShape(width: 236, height: 214, bottomRadius: 66, roundsTopCorners: true))
        #expect(IslandGeometry.shape(.recordingOpen, on: external) == IslandShape(width: 640, height: 226, bottomRadius: 38, roundsTopCorners: true))

        #expect(IslandGeometry.spring(to: .countdown(remaining: 3)) == Motion.islandExpand)
        #expect(IslandGeometry.spring(to: .recordingOpen) == Motion.islandExpand)
        #expect(IslandGeometry.spring(to: .recording) == Motion.islandCollapse)
    }

    @Test func recordingWingsSitBesideTheNotch() {
        #expect(IslandGeometry.wingWidth == 84)
        // A 188 pt notch: a wing of 84 pt on each side of it.
        let top = Self.notchScreen
        let wings = IslandGeometry.shape(.recording, on: top)
        #expect(wings.width == 188 + 2 * 84 && wings.height == top.menuBarHeight)
        #expect(IslandGeometry.frame(wings, on: top) == CGRect(x: 662 - 84, y: 950, width: 356, height: 32))
        // A wider notch (a 16-inch MacBook Pro at "More Space"): the wings keep their width.
        let wider = ScreenTop.make(
            frame: CGRect(x: 0, y: 0, width: 2056, height: 1329), safeAreaTop: 38,
            auxiliaryTopLeft: CGRect(x: 0, y: 1291, width: 928, height: 38),
            auxiliaryTopRight: CGRect(x: 1128, y: 1291, width: 928, height: 38),
            menuBarHeight: 24)
        #expect(IslandGeometry.shape(.recording, on: wider) == IslandShape(width: 200 + 168, height: 38, bottomRadius: 13, roundsTopCorners: false))
        // Without a notch, the pill keeps its own size.
        #expect(IslandGeometry.shape(.recording, on: Self.externalScreen) == IslandShape(width: 300, height: 36, bottomRadius: 17, roundsTopCorners: true))
    }

    @Test func savedShapeFollowsTheDesignTable() {
        let top = Self.notchScreen
        let take = SavedTake(
            projectURL: URL(fileURLWithPath: "/Users/someone/Movies/Toma/Recording.toma", isDirectory: true),
            duration: .seconds(42), markers: 0, trackKinds: [.display], openedEditor: false)
        let saving = IslandShape(width: 490, height: 140, bottomRadius: 32, roundsTopCorners: false)
        #expect(IslandGeometry.shape(.saving, on: top) == saving)
        #expect(IslandGeometry.shape(.saved(take), on: top) == saving)
        // The compact notice: 40 pt under the menu bar's height, whatever the notice.
        #expect(IslandGeometry.shape(.notice(.microphoneSilent), on: top) == IslandShape(width: 360, height: 72, bottomRadius: 20, roundsTopCorners: false))
        #expect(IslandGeometry.shape(.notice(.stoppedForDiskSpace), on: top) == IslandGeometry.shape(.notice(.microphoneSilent), on: top))

        // Without a notch, the same sizes in a pill.
        let external = Self.externalScreen
        #expect(IslandGeometry.shape(.saving, on: external) == IslandShape(width: 490, height: 140, bottomRadius: 36, roundsTopCorners: true))
        #expect(IslandGeometry.shape(.notice(.microphoneSilent), on: external) == IslandShape(width: 360, height: 64, bottomRadius: 24, roundsTopCorners: true))

        for state in [IslandState.notice(.microphoneSilent), .saving, .saved(take)] {
            #expect(IslandGeometry.spring(to: state) == Motion.islandExpand)
        }
    }

    @Test func springsFollowTheDesignTable() {
        #expect(IslandGeometry.spring(to: .open) == Spring(damping: 0.86, response: 0.56))
        #expect(IslandGeometry.spring(to: .choosing) == Spring(damping: 0.86, response: 0.56))
        #expect(IslandGeometry.spring(to: .peek) == Spring(damping: 0.90, response: 0.42))
        #expect(IslandGeometry.spring(to: .rest) == Spring(damping: 1.0, response: 0.48))
    }

    // MARK: - The Replay at rest (fases 4 y 5 plan 5c, decision 15)

    @Test func restWithReplayHasWings() {
        // Under the notch, the wings of a take: a gray dot and «↺ 30 s».
        let top = Self.notchScreen
        let wings = IslandGeometry.shape(.rest, on: top, replaying: true)
        #expect(wings == IslandShape(width: 188 + 2 * 84, height: 32, bottomRadius: 13, roundsTopCorners: false))
        #expect(wings == IslandGeometry.shape(.recording, on: top))
        #expect(IslandGeometry.frame(wings, on: top) == CGRect(x: 662 - 84, y: 950, width: 356, height: 32))
    }

    @Test func restWithReplayWithoutNotchIsThePill() {
        let top = Self.externalScreen
        #expect(IslandGeometry.shape(.rest, on: top, replaying: true) == IslandShape(width: 132, height: 34, bottomRadius: 17, roundsTopCorners: true))
        #expect(IslandGeometry.shape(.rest, on: top, replaying: true) == IslandGeometry.shape(.rest, on: top))
    }

    @Test func restWithoutReplayIsUnchanged() {
        let take = SavedTake(
            projectURL: URL(fileURLWithPath: "/Users/someone/Movies/Toma/Replay.toma", isDirectory: true),
            duration: .seconds(30), markers: 0, trackKinds: [.display], openedEditor: false, replaySeconds: 30)
        let states: [IslandState] = [
            .rest, .peek, .open, .choosing, .countdown(remaining: 3), .recording, .recordingOpen, .notice(.microphoneSilent),
            .saving, .saved(take),
        ]
        for top in [Self.notchScreen, Self.externalScreen] {
            #expect(IslandGeometry.shape(.rest, on: top, replaying: false) == IslandGeometry.shape(.rest, on: top))
            #expect(IslandGeometry.shape(.rest, on: top).width == (top.notch == nil ? 132 : 188))
            // Only the rest has the Replay's wings; peeking from them under a notch keeps their width (checked above).
            for state in states where state != .rest && !(state == .peek && top.notch != nil) {
                #expect(IslandGeometry.shape(state, on: top, replaying: true) == IslandGeometry.shape(state, on: top), "\(state)")
            }
        }
    }
}
