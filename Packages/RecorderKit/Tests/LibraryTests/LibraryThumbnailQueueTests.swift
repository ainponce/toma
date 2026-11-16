// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Library
import ProjectFormat

private func card(_ number: UInt64) -> PackageIdentity {
    PackageIdentity(volume: "V", file: number)
}

@Suite struct LibraryThumbnailQueueTests {
    @Test func onlyCardsOnTheScreenTwoAtATime() {
        var queue = LibraryThumbnailQueue()
        // Nothing before what is needed to decide is known.
        #expect(queue.appeared(card(1)) == [])
        #expect(queue.appeared(card(2)) == [])
        #expect(queue.appeared(card(3)) == [])
        #expect(queue.ready() == [.start(card(1)), .start(card(2))])
        #expect(!queue.isIdle && queue.cardsOnScreen == 3)
        // One ends: the next starts, in the order they appeared.
        #expect(queue.returned(card(1), .image) == [.show(card(1)), .start(card(3))])
        #expect(queue.returned(card(2), .noImage) == [])
        #expect(queue.returned(card(3), .nothing) == [])
        #expect(queue.isIdle)
        // A card that is current is not looked for again when it comes back; one shown by two views counts once.
        #expect(queue.disappeared(card(1)) == [])
        #expect(queue.appeared(card(1)) == [])
        #expect(queue.appeared(card(1)) == [])
        #expect(queue.disappeared(card(1)) == [])
        #expect(queue.cardsOnScreen == 3)
    }

    @Test func aCardThatLeavesIsCancelledAndCountsUntilItReturns() {
        var queue = LibraryThumbnailQueue()
        _ = queue.ready()
        for number: UInt64 in 1...4 { _ = queue.appeared(card(number)) }
        // Card 1 scrolls away: its look is cancelled, but its draw may still run, so nothing new starts yet.
        #expect(queue.disappeared(card(1)) == [.cancel(card(1))])
        // Whatever the cancelled look says is dropped; then card 3 starts.
        #expect(queue.returned(card(1), .image) == [.start(card(3))])
        // A card that leaves before its turn is no longer wanted.
        #expect(queue.disappeared(card(4)) == [])
        #expect(queue.returned(card(2), .image) == [.show(card(2))])
        #expect(queue.returned(card(3), .image) == [.show(card(3))])
        #expect(queue.isIdle)
        // Back on the screen while its cancelled look is still under way: it starts again only once that returns.
        var other = LibraryThumbnailQueue()
        _ = other.ready()
        _ = other.appeared(card(7))
        #expect(other.disappeared(card(7)) == [.cancel(card(7))])
        #expect(other.appeared(card(7)) == [])
        #expect(other.returned(card(7), .noImage) == [.start(card(7))])
    }

    @Test func aChangedProjectIsLookedForAgain() {
        var queue = LibraryThumbnailQueue()
        _ = queue.ready()
        _ = queue.appeared(card(1))
        #expect(queue.returned(card(1), .image) == [.show(card(1))])
        // Its files changed: looked for again (its old image shows meanwhile).
        #expect(queue.changed(card(1)) == [.start(card(1))])
        // It changes again while being looked for: that look is cancelled, and it starts again once it returned.
        #expect(queue.changed(card(1)) == [.cancel(card(1))])
        #expect(queue.returned(card(1), .image) == [.start(card(1))])
        #expect(queue.returned(card(1), .image) == [.show(card(1))])
        // Off the screen, a change is looked for when the card comes back.
        _ = queue.disappeared(card(1))
        #expect(queue.changed(card(1)) == [])
        #expect(queue.appeared(card(1)) == [.start(card(1))])
    }

    /// The card of the take that just ended (review I1): its package is the one being recorded while it is decided, and
    /// its last look can come before or after the take ends.
    @Test func theTakesOwnCardIsLookedForWhenTheTakeEnds() {
        // Its last look comes while the take still records.
        var before = LibraryThumbnailQueue()
        _ = before.ready()
        _ = before.takeChanged(isRecording: true)
        #expect(before.appeared(card(9)) == [.start(card(9))])
        #expect(before.returned(card(9), .afterTheTake) == [])
        #expect(before.changed(card(9)) == [.start(card(9))])
        #expect(before.returned(card(9), .afterTheTake) == [])
        #expect(before.takeChanged(isRecording: false) == [.start(card(9))])
        #expect(before.returned(card(9), .image) == [.show(card(9))])

        // It comes after the take ended.
        var after = LibraryThumbnailQueue()
        _ = after.ready()
        _ = after.takeChanged(isRecording: true)
        _ = after.appeared(card(9))
        #expect(after.returned(card(9), .afterTheTake) == [])
        #expect(after.takeChanged(isRecording: false) == [.start(card(9))])
        #expect(after.changed(card(9)) == [.cancel(card(9))])
        #expect(after.returned(card(9), .image) == [.start(card(9))])

        // Off the screen when the take ends: looked for when it comes back.
        var away = LibraryThumbnailQueue()
        _ = away.ready()
        _ = away.takeChanged(isRecording: true)
        _ = away.appeared(card(9))
        _ = away.returned(card(9), .afterTheTake)
        _ = away.disappeared(card(9))
        #expect(away.takeChanged(isRecording: false) == [])
        #expect(away.appeared(card(9)) == [.start(card(9))])
    }

    @Test func whatATakeKeptFromBeingDrawnIsLookedForAfterIt() {
        var queue = LibraryThumbnailQueue()
        _ = queue.ready()
        _ = queue.takeChanged(isRecording: true)
        _ = queue.appeared(card(1))
        _ = queue.appeared(card(2))
        // During the take the cache is still served; one that had to be drawn comes back with none.
        #expect(queue.returned(card(1), .image) == [.show(card(1))])
        #expect(queue.returned(card(2), .noImage) == [])
        #expect(queue.takeChanged(isRecording: true) == [])
        #expect(queue.takeChanged(isRecording: false) == [.start(card(2))])
        // Outside a take, none is none until the project changes.
        #expect(queue.returned(card(2), .noImage) == [])
        #expect(queue.takeChanged(isRecording: true) == [] && queue.takeChanged(isRecording: false) == [])
    }

    @Test func atMost120ImagesStayOffTheScreen() {
        let count = UInt64(LibraryThumbnailQueue.keptOffScreen) + 2
        // The first two that left go when the 121st and 122nd leave.
        var queue = LibraryThumbnailQueue()
        _ = queue.ready()
        var released: [PackageIdentity] = []
        for number in 1...count {
            _ = queue.appeared(card(number))
            _ = queue.returned(card(number), .image)
            released += queue.disappeared(card(number)).compactMap { if case .release(let id) = $0 { id } else { nil } }
        }
        #expect(released == [card(1), card(2)])
        // One that comes back is looked for again; one back on the screen is no longer counted.
        #expect(queue.appeared(card(1)) == [.start(card(1))])
        #expect(queue.appeared(card(3)) == [])
        #expect(LibraryThumbnailQueue.keptOffScreen == 120 && LibraryThumbnailQueue.concurrent == 2)
    }

    @Test func aThumbnailLookedForByTheUserIsKeptAsAnyOther() {
        var queue = LibraryThumbnailQueue()
        _ = queue.ready()
        // Off the screen: it counts against the images kept off the screen.
        for number in 1...UInt64(LibraryThumbnailQueue.keptOffScreen) {
            _ = queue.appeared(card(number))
            _ = queue.returned(card(number), .image)
            _ = queue.disappeared(card(number))
        }
        #expect(queue.lookedForByTheUser(card(500), .image) == [.show(card(500)), .release(card(1))])
        // During a take, none is looked for again after it.
        _ = queue.takeChanged(isRecording: true)
        _ = queue.appeared(card(600))
        _ = queue.returned(card(600), .nothing)
        #expect(queue.lookedForByTheUser(card(700), .noImage) == [])
        _ = queue.appeared(card(700))
        #expect(queue.takeChanged(isRecording: false) == [.start(card(700))])
    }

    @Test func cardsWithoutAnImageAreLookedForAgainWhenAsked() {
        var queue = LibraryThumbnailQueue()
        _ = queue.ready()
        _ = queue.appeared(card(1))
        _ = queue.appeared(card(2))
        _ = queue.returned(card(1), .image)
        _ = queue.returned(card(2), .nothing)
        #expect(queue.lookAgainWithoutImage() == [.start(card(2))])
    }

    @Test func whereAThumbnailComesFrom() {
        let home = "/Users/demo"
        let local = VolumeInfo(
            uuid: "L", name: "Macintosh HD", isInternal: true, isRemovable: false, isNetwork: false, isSynced: false,
            mountPath: "/")
        var removable = local
        removable.isInternal = false
        removable.isRemovable = true
        var network = local
        network.isNetwork = true
        var synced = local
        synced.isSynced = true
        func summary(
            _ path: String, place: Place = .projectsFolder(subfolder: ""), state: ProjectState = .normal, key: String? = nil
        ) -> ProjectSummary {
            ProjectSummary(
                identity: card(1), path: path, name: "Demo", place: place, hasCamera: false, state: state, thumbnailKey: key,
                lastSeen: Date(timeIntervalSince1970: 0))
        }
        func decide(_ summary: ProjectSummary, _ volume: VolumeInfo?, recording: String? = nil) -> ThumbnailDecision {
            LibraryThumbnailQueue.decide(summary, projectsVolume: volume, recordingPath: recording, home: home)
        }
        let path = "\(home)/Movies/Toma/Demo.toma"
        let url = URL(filePath: path, directoryHint: .isDirectory)
        // The projects folder and its trash on a local disk inside the Mac: drawn.
        #expect(decide(summary(path), local) == .draw(url))
        #expect(decide(summary(path, place: .trash, state: .inTrash(since: Date())), local) == .draw(url))
        #expect(decide(summary(path, state: .readOnlyVolume), local) == .draw(url))
        // The package being recorded: after the take, whatever its state.
        #expect(decide(summary(path, state: .unfinished), local, recording: path) == .afterTheTake)
        #expect(decide(summary(path), local, recording: path) == .afterTheTake)
        // One that cannot be opened: none.
        for state: ProjectState in [
            .unfinished, .needsRepair(RepairReason(part: .manifest, problem: .unreadable)), .newerVersion,
            .unavailable(.notFound),
        ] {
            #expect(decide(summary(path, state: state, key: "k"), local) == ThumbnailDecision.none, "\(state)")
        }
        // A removable disk, or a volume not known yet: only the cache, by the key the index keeps.
        #expect(decide(summary(path, key: "k"), removable) == .cached("k"))
        #expect(decide(summary(path), removable) == ThumbnailDecision.none)
        #expect(decide(summary(path, key: "k"), nil) == .cached("k"))
        // On the network or synced: none, and said.
        #expect(decide(summary(path, key: "k"), network) == .notHere)
        #expect(decide(summary(path, key: "k"), synced) == .notHere)
        // Other places: only the cache; in iCloud Drive or a file provider's folder, by its path, none and said.
        #expect(decide(summary("/Volumes/Trabajo/Demo.toma", place: .elsewhere, key: "k"), local) == .cached("k"))
        #expect(decide(summary("/Volumes/Trabajo/Demo.toma", place: .elsewhere), local) == ThumbnailDecision.none)
        let iCloud = "\(home)/Library/Mobile Documents/com~apple~CloudDocs/Demo.toma"
        let provider = "\(home)/Library/CloudStorage/Dropbox/Demo.toma"
        #expect(decide(summary(iCloud, place: .elsewhere, key: "k"), local) == .notHere)
        #expect(decide(summary(provider, place: .elsewhere, key: "k"), local) == .notHere)
        #expect(decide(summary("\(home)/Library/CloudStorageX/Demo.toma", place: .elsewhere, key: "k"), local) == .cached("k"))
    }
}
