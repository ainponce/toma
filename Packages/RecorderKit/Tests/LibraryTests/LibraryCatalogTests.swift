// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Library
import ProjectFormat

private enum Catalog {
    static let seen = Date(timeIntervalSince1970: 1_794_800_000)

    static func summary(
        _ file: UInt64, name: String = "Demo", place: Place = .projectsFolder(subfolder: ""), recordedAt: Date? = nil,
        state: ProjectState = .normal, size: Int64? = nil, manifest: Int64 = 100, key: String? = nil
    ) -> ProjectSummary {
        ProjectSummary(
            identity: PackageIdentity(volume: "V", file: file), path: "/p/\(name).toma", name: name, place: place,
            recordedAt: recordedAt, hasCamera: false, state: state, size: size,
            manifest: FileSignature(size: manifest, modified: 1), thumbnailKey: key, lastSeen: seen)
    }
}

@Suite struct LibraryCatalogTests {
    /// What an action of the user moved shows where it is at once, before the scanner looks again (design §6.3, §9).
    @Test func anActionsMoveIsShownAtOnce() {
        let demo = Catalog.summary(1, key: "k1")
        var catalog = LibraryCatalog(index: LibraryIndex(projects: [demo]))
        let now = Date(timeIntervalSince1970: 1_794_900_000.6)
        func move(_ path: String, _ place: Place, _ identity: PackageIdentity = demo.identity) -> Bool {
            catalog.move(identity, to: path, place: place, now: now)
        }

        // Renamed: another path and name, the same place, state and thumbnail.
        #expect(move("/p/Demo 2.toma", demo.place))
        let renamed = catalog.summaries[demo.identity]
        #expect(renamed?.path == "/p/Demo 2.toma" && renamed?.name == "Demo 2")
        #expect(renamed?.state == .normal && renamed?.thumbnailKey == "k1")
        #expect(!move("/p/Demo 2.toma", demo.place), "nothing changed")

        // Into the trash: there since now, in whole seconds (rounded down, as the index writes dates).
        #expect(move("/p/Trash/Demo 2.toma", .trash))
        #expect(catalog.summaries[demo.identity]?.place == .trash)
        #expect(catalog.summaries[demo.identity]?.state == .inTrash(since: Date(timeIntervalSince1970: 1_794_900_000)))

        // Out of it: a project like any other until it is read again.
        #expect(move("/p/Clientes/Demo 2.toma", .projectsFolder(subfolder: "Clientes")))
        #expect(catalog.summaries[demo.identity]?.state == .normal)
        #expect(catalog.summaries[demo.identity]?.place == .projectsFolder(subfolder: "Clientes"))

        // One the library does not know: nothing.
        #expect(!move("/p/X.toma", .trash, PackageIdentity(volume: "V", file: 9)))
        #expect(catalog.summaries.count == 1)
    }

    /// The places of `library.json` never leave the library with the index (a lost or dropped index): each the index does
    /// not have is shown from what the records know, without reading anything (design §6.5), until the scanner tells
    /// what it is now, on an action of the user.
    @Test func placesOfTheRecordsOutliveTheIndex() {
        let added = Date(timeIntervalSince1970: 1_794_000_000)
        let demo = OtherPlace(added: added, bookmark: Data([1]), path: "/Volumes/Trabajo/Demo.toma")
        let known = Catalog.summary(7, name: "Known", place: .elsewhere)
        let knownPlace = OtherPlace(added: added, bookmark: Data([2]), path: known.path)
        var catalog = LibraryCatalog(index: LibraryIndex(projects: [known]))
        func keep(_ places: [OtherPlace]) -> Bool { catalog.keep(places) }
        func apply(_ updates: [LibraryUpdate]) -> LibraryChanges { catalog.apply(updates) }

        #expect(keep([demo, knownPlace]))
        #expect(catalog.summaries.count == 2, "the one the index has is not shown twice")
        let shown = catalog.summaries.values.first { $0.path == demo.path }
        #expect(shown?.name == "Demo" && shown?.place == .elsewhere && shown?.lastSeen == added && shown?.state == .normal)
        let identity = shown?.identity
        #expect(identity.map(LibraryCatalog.isFromTheRecords) == true)
        #expect(!LibraryCatalog.isFromTheRecords(known.identity))
        #expect(!keep([demo]), "kept once")
        // The same place gives the same identity in every window (and so in the index written from it).
        var again = LibraryCatalog(index: LibraryIndex())
        _ = again.keep([demo])
        #expect(again.summaries.keys.first == identity)

        // A look that finds nothing tells it with the identity it was shown with: "No disponible".
        if let identity, var unavailable = shown {
            unavailable.state = .unavailable(.diskNotConnected("Trabajo"))
            #expect(apply([.summary(unavailable)]).projects)
            #expect(catalog.summaries[identity]?.state == .unavailable(.diskNotConnected("Trabajo")))
        }
        // A look that finds it: what it is now takes its place, once.
        var real = Catalog.summary(8, name: "Demo", place: .elsewhere)
        real.path = demo.path
        #expect(apply([.summary(real)]).projects)
        #expect(catalog.summaries.values.filter { $0.path == demo.path } == [real])
        #expect(catalog.summaries.count == 2)
    }

    /// What an action took out (deleted for good, out of the library) comes back on undo, unless something newer of it
    /// came meanwhile.
    @Test func whatAnActionTookOutComesBack() {
        let place = Catalog.summary(1, place: .elsewhere)
        var catalog = LibraryCatalog(index: LibraryIndex(projects: [place, Catalog.summary(2, name: "B")]))
        func remove() -> ProjectSummary? { catalog.remove(place.identity) }
        func putBack(_ summary: ProjectSummary) -> Bool { catalog.putBack(summary) }
        #expect(remove() == place)
        #expect(remove() == nil)
        #expect(catalog.summaries.count == 1)

        #expect(putBack(place))
        #expect(catalog.summaries[place.identity] == place)
        // The scanner told it again meanwhile: what it told stays.
        var newer = place
        newer.size = 5_000
        _ = catalog.apply([.summary(newer)])
        #expect(!putBack(place))
        #expect(catalog.summaries[place.identity] == newer)
        // One without an identity is never kept.
        #expect(!putBack(Catalog.summary(0, name: "Nobody")))
    }

    @Test func summariesAreMergedByIdentity() {
        var catalog = LibraryCatalog(index: LibraryIndex(projects: [Catalog.summary(1, key: "k1"), Catalog.summary(2, name: "B")]))
        func apply(_ updates: [LibraryUpdate]) -> LibraryChanges { catalog.apply(updates) }
        func setKey(_ key: String, _ identity: PackageIdentity) -> Bool { catalog.setThumbnailKey(key, for: identity) }
        #expect(catalog.summaries.count == 2 && !catalog.isLookingForProjects)

        // One the scanner read again with the same files keeps the thumbnail key it had; equal to what was known, it
        // changes nothing.
        var same = Catalog.summary(1)
        #expect(apply([.summary(same)]) == LibraryChanges())
        #expect(catalog.summaries[same.identity]?.thumbnailKey == "k1")
        // Its size summed: the projects change, not its thumbnail.
        same.size = 2_000
        #expect(apply([.summary(same)]) == LibraryChanges(projects: true))
        #expect(catalog.summaries[same.identity]?.thumbnailKey == "k1")
        // Its files changed: the key it had is not its own any more, and its thumbnail is looked for again.
        let edited = Catalog.summary(1, manifest: 200)
        #expect(apply([.summary(edited)]) == LibraryChanges(projects: true, thumbnails: [edited.identity]))
        #expect(catalog.summaries[edited.identity]?.thumbnailKey == nil)
        // Moved, or another state: looked for again too. A new one too.
        var moved = edited
        moved.place = .trash
        moved.state = .inTrash(since: Catalog.seen)
        let new = Catalog.summary(3, name: "C")
        #expect(apply([.summary(moved), .summary(new)]) == LibraryChanges(projects: true, thumbnails: [moved.identity, new.identity]))
        // One without an identity is never kept.
        #expect(apply([.summary(Catalog.summary(0, name: "Nobody"))]) == LibraryChanges())
        #expect(catalog.summaries.count == 3)

        // `.removed` drops only the summary, and a `.summary` of the same identity may follow.
        #expect(apply([.removed(new.identity)]) == LibraryChanges(projects: true))
        #expect(apply([.removed(new.identity)]) == LibraryChanges())
        #expect(apply([.summary(new)]) == LibraryChanges(projects: true, thumbnails: [new.identity]))

        // A key found on an action of the user.
        #expect(setKey("k3", new.identity))
        #expect(!setKey("k3", new.identity))
        #expect(!setKey("k9", PackageIdentity(volume: "V", file: 99)))
    }

    @Test func theWalkTheStripAndTheFoot() {
        // Without an index, the first walk is looking for projects until it finishes.
        var catalog = LibraryCatalog(index: LibraryIndex(projects: [Catalog.summary(0)]))
        func apply(_ updates: [LibraryUpdate]) -> LibraryChanges { catalog.apply(updates) }
        #expect(catalog.isLookingForProjects == false)
        catalog = LibraryCatalog(index: LibraryIndex())
        #expect(catalog.isLookingForProjects && catalog.summaries.isEmpty)
        #expect(apply([.progress(found: 340)]) == LibraryChanges(status: true))
        #expect(apply([.progress(found: 340)]) == LibraryChanges())
        #expect(catalog.projectsFound == 340)
        #expect(apply([.waiting(volume: "Trabajo"), .waiting(volume: "iCloud Drive"), .waiting(volume: "Trabajo")])
            == LibraryChanges(status: true))
        #expect(catalog.waitingFor == ["Trabajo", "iCloud Drive"])
        #expect(apply([.waitingEnded(volume: "Trabajo"), .waitingEnded(volume: "Otro")]) == LibraryChanges(status: true))
        #expect(catalog.waitingFor == ["iCloud Drive"])
        #expect(apply([.finished]) == LibraryChanges(status: true, walkFinished: true))
        #expect(!catalog.isLookingForProjects && catalog.walkFinished)

        // The projects folder cannot be read: what was known stays, and the strip holds until a walk ends without it.
        catalog = LibraryCatalog(index: LibraryIndex(projects: [Catalog.summary(1)]))
        #expect(apply([.projectsFolderUnreadable, .finished]) == LibraryChanges(status: true, walkFinished: true))
        #expect(catalog.isFolderUnreadable && catalog.summaries.count == 1)
        // "Volver a intentar": the strip stays while the new walk runs, and again if it finds the same.
        catalog.walkStarted()
        #expect(catalog.isFolderUnreadable && !catalog.walkFinished)
        #expect(apply([.projectsFolderUnreadable, .finished]) == LibraryChanges(walkFinished: true))
        #expect(catalog.isFolderUnreadable)
        catalog.walkStarted()
        #expect(apply([.finished]) == LibraryChanges(status: true, walkFinished: true))
        #expect(!catalog.isFolderUnreadable)
        // Said by a look between walks: it holds until the next walk ends.
        #expect(apply([.projectsFolderUnreadable]) == LibraryChanges(status: true))
        catalog.walkStarted()
        #expect(apply([.finished]) == LibraryChanges(status: true, walkFinished: true))
        #expect(!catalog.isFolderUnreadable)
    }

    @Test func sectionsWithWhatTheAppAndTheRecordsAdd() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Argentina/Buenos_Aires"))
        calendar.locale = Locale(identifier: "es_AR")
        let now = Catalog.seen
        let today = now.addingTimeInterval(-60)
        let yesterday = now.addingTimeInterval(-86_400)
        let projects = [
            Catalog.summary(1, name: "Demo", recordedAt: today, size: 10),
            Catalog.summary(2, name: "Viejo", recordedAt: yesterday, size: 20),
            Catalog.summary(3, name: "Basura", place: .trash, recordedAt: today, state: .inTrash(since: now), size: 300),
            Catalog.summary(4, name: "Afuera", place: .elsewhere, recordedAt: yesterday),
        ]
        let catalog = LibraryCatalog(index: LibraryIndex(projects: projects))
        var records = LibraryRecords()
        records.favorites = [projects[1].identity.string]
        records.lastOpened = [projects[0].identity.string: now]
        let live = LibraryLive(recordingPath: projects[0].path, openHere: [projects[1].path], openElsewhere: [projects[3].path])

        let all = catalog.sections(
            section: .all, search: "", sort: .dateRecorded, ascending: false, records: records, live: live, now: now,
            calendar: calendar)
        // Newest first; the same day by name.
        #expect(all.shown.map(\.summary.name) == ["Demo", "Afuera", "Viejo"])
        #expect(all.groups.map(\.date) == [.today, .yesterday])
        #expect(all.groups.map { $0.items.map(\.summary.name) } == [["Demo"], ["Afuera", "Viejo"]])
        #expect(all.counts == [.all: 3, .favorites: 1, .otherPlaces: 1, .trash: 1])
        #expect(all.trashBytes == 300)
        #expect(all.shown.map(\.live) == [.recording, .openElsewhere, .openHere])
        #expect(all.shown.map(\.favorite) == [false, false, true])
        #expect(all.shown[0].lastOpened == now)

        // Not by date: one group without a date; nothing shown, no group.
        let byName = catalog.sections(
            section: .all, search: "", sort: .name, ascending: true, records: records, live: LibraryLive(), now: now,
            calendar: calendar)
        #expect(byName.groups == [LibraryGroup(date: nil, items: byName.shown)])
        #expect(byName.shown.map(\.summary.name) == ["Afuera", "Demo", "Viejo"])
        #expect(byName.shown.allSatisfy { $0.live == .none })
        let nothing = catalog.sections(
            section: .all, search: "zzz", sort: .name, ascending: true, records: records, live: live, now: now,
            calendar: calendar)
        #expect(nothing.shown.isEmpty && nothing.groups.isEmpty && nothing.counts[.all] == 3)
        let trash = catalog.sections(
            section: .trash, search: "", sort: .dateRecorded, ascending: false, records: records, live: live, now: now,
            calendar: calendar)
        #expect(trash.shown.map(\.summary.name) == ["Basura"])
    }

    @Test func whatTheAppAdds() {
        let summary = Catalog.summary(1)
        #expect(LibraryLive().state(of: summary) == .none)
        // Recording wins over open here, which wins over open elsewhere.
        #expect(
            LibraryLive(recordingPath: summary.path, openHere: [summary.path], openElsewhere: [summary.path]).state(of: summary)
                == .recording)
        #expect(LibraryLive(openHere: [summary.path], openElsewhere: [summary.path]).state(of: summary) == .openHere)
        #expect(LibraryLive(openElsewhere: [summary.path]).state(of: summary) == .openElsewhere)
    }
}
