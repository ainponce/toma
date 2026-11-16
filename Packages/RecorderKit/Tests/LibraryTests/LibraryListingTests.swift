// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Synchronization
import Testing
// Not @testable: the app uses only the public API.
import Library

private enum Listing {
    static let zone = TimeZone(identifier: "America/Argentina/Buenos_Aires")!
    static let spanish = Locale(identifier: "es_AR")

    /// A Gregorian calendar whose week starts on Monday, in a fixed zone and locale.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = spanish
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    static let counter = Mutex<UInt64>(0)

    static func item(
        _ name: String, place: Place = .projectsFolder(subfolder: ""), recorded: Date? = nil, seconds: Double? = nil,
        size: Int64? = nil, favorite: Bool = false, opened: Date? = nil, path: String? = nil
    ) -> LibraryItem {
        let file = counter.withLock { value -> UInt64 in
            value += 1
            return value
        }
        let summary = ProjectSummary(
            identity: PackageIdentity(volume: "V", file: file), path: path ?? "/Users/a/Movies/Toma/\(name).toma",
            name: name, place: place, recordedAt: recorded, outputSeconds: seconds, hasCamera: false, state: .normal,
            size: size, lastSeen: date(2026, 11, 1))
        return LibraryItem(summary: summary, favorite: favorite, lastOpened: opened)
    }

    static func names(_ items: [LibraryItem]) -> [String] { items.map(\.summary.name) }

    static func list(
        _ all: [LibraryItem], _ section: LibrarySection = .all, search: String = "", sort: LibrarySort = .dateRecorded,
        ascending: Bool = false
    ) -> [LibraryItem] {
        LibraryListing.items(all, section: section, search: search, sort: sort, ascending: ascending)
    }
}

@Suite struct LibraryListingTests {
    @Test func searchIgnoresCaseAndAccents() {
        let demo = Listing.item("Démo nueva")
        let clients = Listing.item("Reel", place: .projectsFolder(subfolder: "Clientes"))
        let other = Listing.item("Otro")
        let all = [demo, clients, other]
        #expect(Listing.names(Listing.list(all, search: "demo")) == ["Démo nueva"])
        #expect(Listing.names(Listing.list(all, search: "DEMO")) == ["Démo nueva"])
        #expect(Listing.names(Listing.list(all, search: "démo")) == ["Démo nueva"])
        #expect(Listing.names(Listing.list(all, search: "clientes")) == ["Reel"])
        #expect(Listing.names(Listing.list(all, search: "  clientes  ")) == ["Reel"])
        #expect(Listing.list(all, search: "zzz").isEmpty)
        #expect(Listing.list(all, search: "").count == 3)
        #expect(Listing.list(all, search: "   ").count == 3)
    }

    @Test func searchAlsoFindsTheFolderOfAProjectOfOtherPlacesAndEveryLevel() {
        let deep = Listing.item("A", place: .projectsFolder(subfolder: "Clientes/Acme"))
        let away = Listing.item("B", place: .elsewhere, path: "/Volumes/Trabajo/B.toma")
        #expect(Listing.names(Listing.list([deep, away], search: "acme")) == ["A"])
        #expect(Listing.names(Listing.list([deep, away], search: "volumes")) == ["B"])
    }

    @Test func subfolderGivesThePlaceComponents() {
        #expect(LibraryListing.subfolder(Listing.item("a").summary) == [])
        #expect(LibraryListing.subfolder(Listing.item("a", place: .projectsFolder(subfolder: "Clientes")).summary) == ["Clientes"])
        #expect(
            LibraryListing.subfolder(Listing.item("a", place: .projectsFolder(subfolder: "Clientes/Acme")).summary)
                == ["Clientes", "Acme"])
        #expect(LibraryListing.subfolder(Listing.item("a", place: .trash).summary) == [])
        #expect(
            LibraryListing.subfolder(Listing.item("a", place: .elsewhere, path: "/Volumes/Trabajo/a.toma").summary)
                == ["/Volumes/Trabajo"])
    }

    @Test func sectionsAndCounts() {
        let all = [
            Listing.item("a", favorite: true), Listing.item("b"), Listing.item("c", place: .projectsFolder(subfolder: "X")),
            Listing.item("d", place: .elsewhere), Listing.item("e", place: .trash), Listing.item("f", place: .trash, favorite: true),
        ]
        let counts = LibraryListing.counts(all)
        #expect(counts == [.all: 4, .favorites: 1, .otherPlaces: 1, .trash: 2])
        #expect(Set(Listing.names(Listing.list(all, .all))) == ["a", "b", "c", "d"])
        #expect(Listing.names(Listing.list(all, .favorites)) == ["a"])
        #expect(Listing.names(Listing.list(all, .otherPlaces)) == ["d"])
        #expect(Set(Listing.names(Listing.list(all, .trash))) == ["e", "f"])
        #expect(LibraryListing.counts([]) == [.all: 0, .favorites: 0, .otherPlaces: 0, .trash: 0])
    }

    @Test func searchRespectsTheSection() {
        let all = [Listing.item("Demo"), Listing.item("Demo viejo", place: .trash)]
        #expect(Listing.names(Listing.list(all, .all, search: "demo")) == ["Demo"])
        #expect(Listing.names(Listing.list(all, .trash, search: "demo")) == ["Demo viejo"])
    }

    @Test func sortByEveryColumnBothWays() {
        let t: (Int, Int, Int) -> Date = { Listing.date($0, $1, $2) }
        let a = Listing.item("a", recorded: t(2026, 11, 1), seconds: 30, size: 300, opened: t(2026, 11, 5))
        let b = Listing.item("b", recorded: t(2026, 11, 3), seconds: 10, size: 100, opened: t(2026, 11, 2))
        let c = Listing.item("c", recorded: t(2026, 11, 2), seconds: 20, size: 200, opened: t(2026, 11, 9))
        let all = [a, b, c]
        let expectations: [(LibrarySort, [String])] = [
            (.dateRecorded, ["a", "c", "b"]), (.name, ["a", "b", "c"]), (.duration, ["b", "c", "a"]),
            (.size, ["b", "c", "a"]), (.lastOpened, ["b", "a", "c"]),
        ]
        #expect(Set(expectations.map(\.0)) == Set(LibrarySort.allCases))
        for (sort, ascending) in expectations {
            #expect(Listing.names(Listing.list(all, sort: sort, ascending: true)) == ascending, "\(sort) up")
            #expect(Listing.names(Listing.list(all, sort: sort, ascending: false)) == ascending.reversed(), "\(sort) down")
        }
    }

    @Test func nameSortIsNaturalAndIgnoresAccentsAndCase() {
        let all = ["Grabación 10", "grabación 2", "Álamo", "beta"].map { Listing.item($0) }
        #expect(Listing.names(Listing.list(all, sort: .name, ascending: true)) == ["Álamo", "beta", "grabación 2", "Grabación 10"])
    }

    @Test func tiesGoByNameWhicheverWayTheListGoes() {
        let same = Listing.date(2026, 11, 1)
        let all = [Listing.item("b", size: 5), Listing.item("a", size: 5), Listing.item("c", size: 5)]
        #expect(Listing.names(Listing.list(all, sort: .size, ascending: true)) == ["a", "b", "c"])
        #expect(Listing.names(Listing.list(all, sort: .size, ascending: false)) == ["a", "b", "c"])
        let dated = [Listing.item("y", recorded: same), Listing.item("x", recorded: same)]
        #expect(Listing.names(Listing.list(dated, sort: .dateRecorded, ascending: false)) == ["x", "y"])
        // The same name in two folders: the path decides.
        let twins = [
            Listing.item("t", place: .projectsFolder(subfolder: "B"), path: "/p/B/t.toma"),
            Listing.item("t", place: .projectsFolder(subfolder: "A"), path: "/p/A/t.toma"),
        ]
        #expect(Listing.list(twins, sort: .name, ascending: true).map(\.summary.path) == ["/p/A/t.toma", "/p/B/t.toma"])
        #expect(Listing.list(twins, sort: .name, ascending: false).map(\.summary.path) == ["/p/A/t.toma", "/p/B/t.toma"])
    }

    @Test func aMissingValueGoesLastInBothDirections() {
        // A take still recording has no length; one never opened has no last opening; one that cannot be read, no date.
        let recording = Listing.item("grabando", recorded: Listing.date(2026, 11, 1), seconds: nil, size: nil)
        let done = Listing.item("hecho", recorded: Listing.date(2026, 11, 2), seconds: 5, size: 7, opened: Listing.date(2026, 11, 3))
        let unreadable = Listing.item("roto", recorded: nil)
        let all = [recording, unreadable, done]
        for ascending in [true, false] {
            #expect(Listing.names(Listing.list(all, sort: .duration, ascending: ascending)).first == "hecho")
            #expect(Listing.names(Listing.list(all, sort: .size, ascending: ascending)).first == "hecho")
            #expect(Listing.names(Listing.list(all, sort: .lastOpened, ascending: ascending)).first == "hecho")
            #expect(Listing.names(Listing.list(all, sort: .dateRecorded, ascending: ascending)).last == (ascending ? "roto" : "roto"))
        }
        // The ones without the value keep the name order among themselves.
        #expect(Listing.names(Listing.list(all, sort: .duration, ascending: false)) == ["hecho", "grabando", "roto"])
        #expect(Listing.names(Listing.list(all, sort: .duration, ascending: true)) == ["hecho", "grabando", "roto"])
    }

    @Test func searchWithNilsDoesNotCrash() {
        let recording = Listing.item("Grabando", recorded: nil, seconds: nil)
        #expect(Listing.list([recording], search: "grab").count == 1)
    }

    @Test func dateGroupsTodayYesterdayWeekdaysThenMonths() {
        let calendar = Listing.calendar
        // Thursday 19 November 2026; the week starts on Monday 16.
        let now = Listing.date(2026, 11, 19, 15)
        #expect(calendar.component(.weekday, from: now) == 5)
        let items = [
            Listing.item("hoy", recorded: Listing.date(2026, 11, 19, 9)),
            Listing.item("hoy2", recorded: Listing.date(2026, 11, 19, 0)),
            Listing.item("ayer", recorded: Listing.date(2026, 11, 18, 23)),
            Listing.item("martes", recorded: Listing.date(2026, 11, 17, 10)),
            Listing.item("lunes", recorded: Listing.date(2026, 11, 16, 0)),
            Listing.item("domingo", recorded: Listing.date(2026, 11, 15, 23)),
            Listing.item("nov", recorded: Listing.date(2026, 11, 2)),
            Listing.item("oct", recorded: Listing.date(2026, 10, 31, 23)),
            Listing.item("oct2", recorded: Listing.date(2026, 10, 1)),
            Listing.item("viejo", recorded: Listing.date(2025, 12, 31)),
        ]
        let groups = LibraryListing.groups(items, now: now, calendar: calendar)
        #expect(groups.map(\.group) == [
            .today, .yesterday, .weekday(3), .weekday(2), .month(year: 2026, month: 11), .month(year: 2026, month: 10),
            .month(year: 2025, month: 12),
        ])
        #expect(groups.map { Listing.names($0.items) } == [
            ["hoy", "hoy2"], ["ayer"], ["martes"], ["lunes"], ["domingo", "nov"], ["oct", "oct2"], ["viejo"],
        ])
        #expect(groups.map { $0.group.title(calendar: calendar) } == [
            "Hoy", "Ayer", "Martes", "Lunes", "Noviembre de 2026", "Octubre de 2026", "Diciembre de 2025",
        ])
    }

    @Test func mondayHasYesterdayFromLastWeekAndNoWeekdays() {
        let calendar = Listing.calendar
        let monday = Listing.date(2026, 11, 16, 8)
        let items = [
            Listing.item("hoy", recorded: Listing.date(2026, 11, 16, 1)),
            Listing.item("domingo", recorded: Listing.date(2026, 11, 15, 20)),
            Listing.item("sabado", recorded: Listing.date(2026, 11, 14, 20)),
        ]
        let groups = LibraryListing.groups(items, now: monday, calendar: calendar)
        #expect(groups.map(\.group) == [.today, .yesterday, .month(year: 2026, month: 11)])
    }

    @Test func aProjectWithoutADateGoesByWhenItWasSeenAndOneFromTheFutureGoesToday() {
        let calendar = Listing.calendar
        let now = Listing.date(2026, 11, 19)
        let unread = Listing.item("roto")  // lastSeen is 1 November
        let future = Listing.item("futuro", recorded: Listing.date(2026, 11, 25))
        let groups = LibraryListing.groups([future, unread], now: now, calendar: calendar)
        #expect(groups.map(\.group) == [.today, .month(year: 2026, month: 11)])
        #expect(LibraryListing.groups([], now: now, calendar: calendar).isEmpty)
    }

    @Test func groupsFollowTheWeekOfTheCalendarNotAlwaysMonday() {
        var sunday = Listing.calendar
        sunday.firstWeekday = 1
        // Thursday 19; with the week from Sunday, the 15th is this week.
        let now = Listing.date(2026, 11, 19)
        let groups = LibraryListing.groups([Listing.item("d", recorded: Listing.date(2026, 11, 15))], now: now, calendar: sunday)
        #expect(groups.map(\.group) == [.weekday(1)])
        #expect(groups[0].group.title(calendar: sunday) == "Domingo")
    }

    @Test func monthTitleFollowsTheLocale() {
        var english = Listing.calendar
        english.locale = Locale(identifier: "en_US")
        #expect(DateGroup.month(year: 2026, month: 11).title(calendar: english) == "November 2026")
        #expect(DateGroup.month(year: 2026, month: 3).title(calendar: Listing.calendar) == "Marzo de 2026")
        #expect(DateGroup.weekday(4).title(calendar: Listing.calendar) == "Miércoles")
        #expect(DateGroup.weekday(9).title(calendar: Listing.calendar) == "")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
    func searchAThousandWhileTyping() {
        let words = ["Demo", "Reel", "Grabación", "Lanzamiento", "Cliente", "Tutorial", "Revisión", "Función"]
        var all: [LibraryItem] = []
        for i in 0..<1000 {
            let name: String = "\(words[i % 8]) \(words[(i / 8) % 8]) \(i)"
            let place: Place = .projectsFolder(subfolder: i % 3 == 0 ? "Clientes/Acme" : "")
            let recorded = Date(timeIntervalSince1970: 1_790_000_000 + Double(i) * 3600)
            all.append(Listing.item(name, place: place, recorded: recorded, seconds: Double(i % 300), size: Int64(i) * 1000))
        }
        var times: [Double] = []
        var found = 0
        for round in 0..<(100 + 5) {
            let clock = ContinuousClock()
            let start = clock.now
            found = Listing.list(all, search: round % 2 == 0 ? "demo r" : "revision", sort: .dateRecorded).count
            let elapsed = clock.now - start
            if round >= 5 { times.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3) }
        }
        times.sort()
        let median = times[times.count / 2]
        print("searchAThousandWhileTyping: median \(median) ms, max \(times.last!) ms, found \(found), 1000 items")
        #expect(median <= 8)
    }
}
