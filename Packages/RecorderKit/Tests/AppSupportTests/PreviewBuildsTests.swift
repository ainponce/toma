// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Testing

/// Which preview builds the editor shows (final review D-I1): a drag's builds, which used to be thrown away, and never a
/// stale one (Task 34).
@Test func theBuildsOfADragAreShownOneAfterAnother() {
    var builds = PreviewBuilds()
    let opened = builds.request(revision: 3, ofGesture: false)
    #expect(shown(&builds, opened, playheadRevision: 3))
    builds.beginGesture()
    // The drag asks faster than builds come back: the second request replaces the first still waiting, which is never
    // built; each one that comes back is shown, as long as nothing newer is on screen.
    let first = builds.request(revision: 3, ofGesture: true)
    let second = builds.request(revision: 3, ofGesture: true)
    let third = builds.request(revision: 3, ofGesture: true)
    #expect(shown(&builds, first, playheadRevision: 3))
    #expect(shown(&builds, third, playheadRevision: 3))
    #expect(!shown(&builds, second, playheadRevision: 3), "older than the one on screen")
}

@Test func aDragsBuildsStopWithIt() {
    for gaveUp in [false, true] {
        var builds = PreviewBuilds()
        builds.beginGesture()
        let late = builds.request(revision: 0, ofGesture: true)
        builds.endGesture()
        // Ended: one perform, a new revision; given up: the session's revision again.
        let session = builds.request(revision: gaveUp ? 0 : 1, ofGesture: false)
        #expect(!shown(&builds, late, playheadRevision: gaveUp ? 0 : 1), "the gesture's look once it is over")
        #expect(shown(&builds, session, playheadRevision: gaveUp ? 0 : 1))
    }
    // A later gesture's builds are its own.
    var builds = PreviewBuilds()
    builds.beginGesture()
    let old = builds.request(revision: 0, ofGesture: true)
    builds.endGesture()
    builds.beginGesture()
    let new = builds.request(revision: 0, ofGesture: true)
    #expect(!shown(&builds, old, playheadRevision: 0))
    #expect(shown(&builds, new, playheadRevision: 0))
}

/// Task 34: a build of a revision older than the one the playhead is counted in is dropped, the newer one on its way.
@Test func aBuildOlderThanThePlayheadsRevisionIsDropped() {
    var builds = PreviewBuilds()
    let five = builds.request(revision: 5, ofGesture: false)
    let six = builds.request(revision: 6, ofGesture: false)
    // Paused meanwhile: the playhead moved into revision 6.
    #expect(!shown(&builds, five, playheadRevision: 6))
    #expect(shown(&builds, six, playheadRevision: 6))
    // Playing, the playhead stays in the revision being played until a newer one's build is shown.
    var playing = PreviewBuilds()
    let seven = playing.request(revision: 7, ofGesture: false)
    #expect(shown(&playing, seven, playheadRevision: 6))
    // Before the project's first scene, nothing to compare with.
    var opening = PreviewBuilds()
    let first = opening.request(revision: 0, ofGesture: false)
    #expect(shown(&opening, first, playheadRevision: nil))
}

@Test func aGestureBuildOfAnOlderRevisionThanThePlayheadsIsDropped() {
    var builds = PreviewBuilds()
    builds.beginGesture()
    let stale = builds.request(revision: 2, ofGesture: true)
    #expect(!shown(&builds, stale, playheadRevision: 3))
    let fresh = builds.request(revision: 3, ofGesture: true)
    #expect(shown(&builds, fresh, playheadRevision: 3))
}

@Test func aSessionBuildWithoutAGestureIsNeverAGesturesLook() {
    var builds = PreviewBuilds()
    let ticket = builds.request(revision: 0, ofGesture: true)
    #expect(ticket.gesture == nil, "no gesture lasts: a session revision")
    #expect(shown(&builds, ticket, playheadRevision: 0))
}

/// `builds.accepts(ticket, playheadRevision:)`, outside `#expect`, which cannot call a mutating method.
private func shown(_ builds: inout PreviewBuilds, _ ticket: PreviewBuilds.Ticket, playheadRevision: Int?) -> Bool {
    builds.accepts(ticket, playheadRevision: playheadRevision)
}
