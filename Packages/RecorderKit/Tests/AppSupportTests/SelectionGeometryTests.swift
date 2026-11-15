// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import CoreGraphics
import Foundation
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

    // MARK: - Choosing a window

    /// Toma's own window, a window over the menu bar, a window too small to choose, then Safari over Finder:
    /// front to back, as `CGWindowListCopyWindowInfo` lists them.
    private static let ownPID: Int32 = 99
    private static let windows = [
        WindowCandidate(windowID: 1, ownerPID: ownPID, ownerName: "Toma", title: nil, frame: Rect(x: 0, y: 0, width: 1512, height: 982), layer: 0),
        WindowCandidate(windowID: 2, ownerPID: 10, ownerName: "Control Center", title: nil, frame: Rect(x: 0, y: 0, width: 1512, height: 982), layer: 25),
        WindowCandidate(windowID: 3, ownerPID: 11, ownerName: "Notes", title: "Tiny", frame: Rect(x: 390, y: 290, width: 20, height: 20), layer: 0),
        WindowCandidate(windowID: 4, ownerPID: 12, ownerName: "Safari", title: "Start", frame: Rect(x: 300, y: 200, width: 800, height: 600), layer: 0),
        WindowCandidate(windowID: 5, ownerPID: 13, ownerName: "Finder", title: "Home", frame: Rect(x: 100, y: 100, width: 1000, height: 700), layer: 0),
    ]

    @Test func hitTestPicksFrontmostWindowUnderPoint() {
        let point = CGPoint(x: 400, y: 300)
        #expect(Self.windows.allSatisfy { CursorGeometry.contains(point, $0.frame) })
        #expect(WindowHitTest.topmost(at: point, in: Self.windows, excludingPID: Self.ownPID)?.windowID == 4)
        // Outside Safari, Finder is the one in front.
        #expect(WindowHitTest.topmost(at: CGPoint(x: 150, y: 150), in: Self.windows, excludingPID: Self.ownPID)?.windowID == 5)
        // Toma's own window counts once it is another app's.
        #expect(WindowHitTest.topmost(at: point, in: Self.windows, excludingPID: 1)?.windowID == 1)
        #expect(WindowHitTest.minimumSide == 40)
    }

    @Test func hitTestFindsNothingOnTheDesktop() {
        #expect(WindowHitTest.topmost(at: CGPoint(x: 1300, y: 900), in: Self.windows, excludingPID: Self.ownPID) == nil)
        #expect(WindowHitTest.topmost(at: CGPoint(x: 400, y: 300), in: [], excludingPID: Self.ownPID) == nil)
    }

    @Test func windowCandidateReadsTheWindowServerEntry() throws {
        let info: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: 42), kCGWindowOwnerPID as String: NSNumber(value: 12),
            kCGWindowOwnerName as String: "Safari", kCGWindowName as String: "Start", kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowBounds as String: CGRect(x: -1500, y: 20, width: 800, height: 600).dictionaryRepresentation,
        ]
        #expect(WindowCandidate(windowInfo: info) == WindowCandidate(
            windowID: 42, ownerPID: 12, ownerName: "Safari", title: "Start", frame: Rect(x: -1500, y: 20, width: 800, height: 600), layer: 0))
        // Without a title (no Screen Recording permission) or an owner's name, it is still a window.
        var untitled = info
        untitled[kCGWindowName as String] = ""
        untitled[kCGWindowOwnerName as String] = nil
        let window = try #require(WindowCandidate(windowInfo: untitled))
        #expect(window.title == nil && window.ownerName.isEmpty)
        // Without its number or its bounds, it is not.
        var nameless = info
        nameless[kCGWindowNumber as String] = nil
        #expect(WindowCandidate(windowInfo: nameless) == nil)
        var boundless = info
        boundless[kCGWindowBounds as String] = nil
        #expect(WindowCandidate(windowInfo: boundless) == nil)
    }

    // MARK: - Drawing an area

    @Test(arguments: [
        (CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 400), AspectLock.wide16x9, Rect(x: 100, y: 100, width: 300, height: 169)),
        (CGPoint(x: 400, y: 400), CGPoint(x: 100, y: 100), .wide16x9, Rect(x: 100, y: 231, width: 300, height: 169)),
        (CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 500), .free, Rect(x: 100, y: 100, width: 200, height: 400)),
    ])
    func areaDragFollowsTheLock(start: CGPoint, end: CGPoint, lock: AspectLock, expected: Rect) {
        #expect(AreaDrag.rect(from: start, to: end, within: Rect(x: 0, y: 0, width: 1512, height: 982), lock: lock) == expected)
    }

    @Test func areaDragClampsToDisplayAndMinimumSize() {
        let d = Rect(x: -1920, y: -200, width: 1920, height: 1080)
        #expect(AreaDrag.rect(from: CGPoint(x: -100, y: 800), to: CGPoint(x: 200, y: 1000), within: d, lock: .free) == Rect(x: -100, y: 800, width: 100, height: 80))
        #expect(AreaDrag.rect(from: CGPoint(x: -500, y: 100), to: CGPoint(x: -490, y: 110), within: d, lock: .free) == Rect(x: -500, y: 100, width: 64, height: 64))
        #expect(AreaDrag.rect(from: CGPoint(x: -30, y: 850), to: CGPoint(x: -25, y: 855), within: d, lock: .free) == Rect(x: -64, y: 816, width: 64, height: 64))
        #expect(AreaDrag.minimumSide == 64)
    }

    @Test func areaDragWithALockShrinksBothSidesToFit() {
        let main = Rect(x: 0, y: 0, width: 1512, height: 982)
        // Too tall for the room below the anchor: the height is the room, and the width follows it.
        #expect(AreaDrag.rect(from: CGPoint(x: 100, y: 900), to: CGPoint(x: 500, y: 1100), within: main, lock: .wide16x9)
            == Rect(x: 100, y: 900, width: 145, height: 82))
        // Too wide for the room right of the anchor, and then below the smallest 16:9: moved inside.
        #expect(AreaDrag.rect(from: CGPoint(x: 1400, y: 100), to: CGPoint(x: 1700, y: 400), within: main, lock: .wide16x9)
            == Rect(x: 1398, y: 100, width: 114, height: 64))
        // The smallest of each proportion has 64 pt on its shorter side.
        let tiny = (CGPoint(x: 500, y: 500), CGPoint(x: 501, y: 501))
        #expect(AreaDrag.rect(from: tiny.0, to: tiny.1, within: main, lock: .tall9x16) == Rect(x: 500, y: 500, width: 64, height: 114))
        #expect(AreaDrag.rect(from: tiny.0, to: tiny.1, within: main, lock: .square) == Rect(x: 500, y: 500, width: 64, height: 64))
        #expect(AreaDrag.rect(from: tiny.0, to: tiny.1, within: main, lock: .classic4x3) == Rect(x: 500, y: 500, width: 86, height: 65))
        // Whole points, whatever the pointer's.
        #expect(AreaDrag.rect(from: CGPoint(x: 10.4, y: 10.6), to: CGPoint(x: 210.2, y: 110.9), within: main, lock: .free)
            == Rect(x: 10, y: 11, width: 200, height: 100))
    }

    @Test func areaMovesInsideItsDisplay() {
        let main = Rect(x: 0, y: 0, width: 1512, height: 982)
        let area = Rect(x: 100, y: 100, width: 300, height: 169)
        #expect(AreaDrag.moved(area, by: CGVector(dx: 20.4, dy: -30.6), within: main) == Rect(x: 120, y: 69, width: 300, height: 169))
        #expect(AreaDrag.moved(area, by: CGVector(dx: 2000, dy: -500), within: main) == Rect(x: 1212, y: 0, width: 300, height: 169))
    }

    @Test func aspectLocksHaveTheirProportions() {
        #expect(AspectLock.allCases == [.free, .wide16x9, .tall9x16, .square, .classic4x3])
        #expect(AspectLock.free.ratio == nil)
        #expect(AspectLock.wide16x9.ratio == 16.0 / 9 && AspectLock.tall9x16.ratio == 9.0 / 16)
        #expect(AspectLock.square.ratio == 1 && AspectLock.classic4x3.ratio == 4.0 / 3)
        // An area says the proportion it was drawn with, as `AreaDrag` rounds it.
        #expect(AspectLock.matching(Rect(x: 0, y: 0, width: 300, height: 169)) == .wide16x9)
        #expect(AspectLock.matching(Rect(x: 0, y: 0, width: 64, height: 114)) == .tall9x16)
        #expect(AspectLock.matching(Rect(x: 0, y: 0, width: 86, height: 65)) == .classic4x3)
        #expect(AspectLock.matching(Rect(x: 0, y: 0, width: 200, height: 200)) == .square)
        #expect(AspectLock.matching(Rect(x: 0, y: 0, width: 200, height: 400)) == .free)
    }

    // MARK: - Saved areas

    @Test func savedAreasKeepEightMostRecentWithoutDuplicates() {
        let areas = (1...10).map { AreaChoice(displayID: 1, rect: Rect(x: Double($0), y: 0, width: 640, height: 360)) }
        var saved = SavedAreas()
        for area in areas { saved.remember(area) }
        #expect(saved.areas == Array(areas.reversed().prefix(8)))
        saved.remember(areas[2])
        #expect(saved.areas.count == SavedAreas.limit && SavedAreas.limit == 8)
        #expect(saved.areas.first == areas[2])
        #expect(Set(saved.areas.map(\.rect.x)).count == 8)
        // The same rectangle on another display is another area.
        saved.remember(AreaChoice(displayID: 2, rect: areas[2].rect))
        #expect(saved.areas.prefix(2).map(\.displayID) == [2, 1])
        // Made from a list, the first is the most recent, and the list keeps the same rules.
        #expect(SavedAreas(areas: areas + [areas[0]]).areas == Array(areas.prefix(8)))
    }
}
