// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import CoreGraphics
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
        #expect(IslandGeometry.shape(.peek, on: top) == IslandShape(width: 278, height: 46, bottomRadius: 21, roundsTopCorners: false))
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

    @Test func springsFollowTheDesignTable() {
        #expect(IslandGeometry.spring(to: .open) == Spring(damping: 0.86, response: 0.56))
        #expect(IslandGeometry.spring(to: .choosing) == Spring(damping: 0.86, response: 0.56))
        #expect(IslandGeometry.spring(to: .peek) == Spring(damping: 0.90, response: 0.42))
        #expect(IslandGeometry.spring(to: .rest) == Spring(damping: 1.0, response: 0.48))
    }
}
