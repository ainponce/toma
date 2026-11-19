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

@Test func autoStageFollowsTheContent() {
    typealias F = ScreenFollowFixtures
    let wide = F.display(1, frame: Rect(x: 0, y: 0, width: 2400, height: 1000))
    let take = F.makeTake([wide])
    var document = EditDocument.legacy(take: take, events: [])
    let screens = TakeScreens(take: take, events: [])
    // `auto`: the stage is the content's ratio tall by 1; the screens read once say the same as the events.
    document.aspect = .auto
    let auto = StagePoints(take: take, document: document, screens: screens)
    #expect(auto.contentRatio == 2.4 && auto.stageSize == SIMD2(2.4, 1))
    #expect(screens.contentRatio(take: take, document: document) == 2.4)
    #expect(StagePoints(take: take, events: [], document: document).stageSize == SIMD2(2.4, 1))
    // A content within 1 % of 16:9 is 16:9.
    let ordinary = F.makeTake([F.display(1, frame: Rect(x: 0, y: 0, width: 1440, height: 810))])
    #expect(StagePoints(take: ordinary, events: [], document: .legacy(take: ordinary, events: []).with(aspect: .auto)).stageSize == SIMD2(16.0 / 9, 1))
    // The fixed aspects do not follow it, and keep their stage.
    for (aspect, width) in [(Aspect.landscape, 16.0 / 9), (.portrait, 9.0 / 16), (.square, 1), (.fourByFive, 0.8)] {
        document.aspect = aspect
        #expect(StagePoints(take: take, document: document, screens: screens).stageSize == SIMD2(width, 1), "\(aspect)")
    }
    // The macOS window of an `auto` stage is placed in the content's output.
    document.aspect = .auto
    document.style.frame = .macWindow(appearance: .dark, title: "x", buttons: true)
    let window = StagePoints(take: take, document: document, screens: screens)
    let rect = window.screenRect(at: F.at(1))
    #expect(rect != nil && rect!.width > 0 && rect!.width <= 2.4)
}

private extension EditDocument {
    func with(aspect: Aspect) -> EditDocument {
        var copy = self
        copy.aspect = aspect
        return copy
    }
}
