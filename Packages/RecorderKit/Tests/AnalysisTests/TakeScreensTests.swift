// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat
import Testing

// `StagePoints` from the take's screens read once (`TakeScreens`) is the one from the events (final review D-I3): the
// editor makes it for each revision without going over the take's events on the main thread.

@Test func stagePointsFromTheTakesScreensAreThoseFromItsEvents() throws {
    typealias F = ScreenFollowFixtures
    let take = F.makeTake()
    // The display moves and changes shape mid-take; the pointer wanders over both displays.
    var events = [
        InputEvent(t: F.at(-0.01), kind: .displayGeometry(displayID: 1, frame: F.frame1, scale: 2)),
        InputEvent(t: F.at(12), kind: .displayGeometry(displayID: 1, frame: Rect(x: 0, y: 0, width: 1280, height: 800), scale: 2)),
        InputEvent(t: F.at(30), kind: .displayGeometry(displayID: 2, frame: Rect(x: 1280, y: 0, width: 1920, height: 1080), scale: 1)),
    ]
    events += (0..<600).map { F.pointer(Double($0) / 10, on: $0 % 70 < 35 ? 1 : 2) }
    var document = EditDocument.legacy(take: take, events: events)
    document.screens.changes = [
        ScreenChange(id: "s-00000001", take: F.takeID, t: F.at(20), track: "display-2", origin: .user),
        ScreenChange(id: "s-00000002", take: F.takeID, t: F.at(40), track: "display-1", origin: .user),
    ]
    let screens = TakeScreens(take: take, events: events.shuffled())
    for frame in [WindowFrame.none, .macWindow(appearance: .dark, title: "x", buttons: true)] {
        document.style.frame = frame
        let fromEvents = StagePoints(take: take, events: events, document: document)
        let fromScreens = StagePoints(take: take, document: document, screens: screens)
        #expect(fromScreens.screenTrackIDs == fromEvents.screenTrackIDs)
        for seconds in stride(from: -1.0, through: 61, by: 0.7) {
            let host = F.at(seconds)
            #expect(fromScreens.screenRect(at: host) == fromEvents.screenRect(at: host), "at \(seconds) s")
            #expect(fromScreens.shownScreen(at: host)?.track == fromEvents.shownScreen(at: host)?.track)
            for point in [SIMD2(700.0, 450), SIMD2(2000, 500), SIMD2(1300, 790)] {
                #expect(fromScreens.stagePoint(global: point, at: host) == fromEvents.stagePoint(global: point, at: host))
            }
        }
    }
}
