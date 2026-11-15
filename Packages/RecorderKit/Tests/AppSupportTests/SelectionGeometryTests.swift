// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import CoreGraphics
import ProjectFormat
import Testing

@Suite struct SelectionGeometryTests {
    /// The built-in display is the main one; the external one is up and to the left of it.
    private static let displays = [
        DisplayInfo(id: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982), scale: 2, isMain: true, maximumFramesPerSecond: 120),
        DisplayInfo(id: 2, frame: Rect(x: -1920, y: -200, width: 1920, height: 1080), scale: 1, isMain: false, maximumFramesPerSecond: 60),
    ]

    @Test func globalAndAppKitCoordinatesRoundTripOnASecondaryDisplay() {
        let global = Rect(x: -1920, y: -200, width: 1920, height: 1080)
        let appKit = CGRect(x: -1920, y: 102, width: 1920, height: 1080)
        #expect(ScreenCoordinates.appKit(fromGlobal: global, primaryScreenHeight: 982) == appKit)
        #expect(ScreenCoordinates.global(fromAppKit: appKit, primaryScreenHeight: 982) == global)
        // The main display is the same in both.
        let main = Rect(x: 0, y: 0, width: 1512, height: 982)
        #expect(ScreenCoordinates.appKit(fromGlobal: main, primaryScreenHeight: 982) == CGRect(x: 0, y: 0, width: 1512, height: 982))
    }

    @Test func islandFollowsThePointerScreen() {
        #expect(IslandPlacement.displayID(containing: CGPoint(x: -960, y: 340), displays: Self.displays) == 2)
        #expect(IslandPlacement.displayID(containing: CGPoint(x: 700, y: 20), displays: Self.displays) == 1)
        // Off every display: the main one, wherever it is listed.
        #expect(IslandPlacement.displayID(containing: CGPoint(x: 5000, y: 5000), displays: Self.displays) == 1)
        #expect(IslandPlacement.displayID(containing: CGPoint(x: 5000, y: 5000), displays: Self.displays.reversed()) == 1)
        #expect(IslandPlacement.displayID(containing: CGPoint(x: 10, y: 10), displays: []) == nil)
    }
}
