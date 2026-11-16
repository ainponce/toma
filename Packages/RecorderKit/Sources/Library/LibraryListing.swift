// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What the app knows about a project that the library cannot read from its folder (design §6.6): whether this app is
/// recording into it, has it open, or another app has it open.
public enum LiveState: Equatable, Sendable {
    case none, recording, openHere, openElsewhere
}

/// One row of the library: what was read of a project plus what the app and `library.json` add.
public struct LibraryItem: Equatable, Sendable {
    public var summary: ProjectSummary
    public var favorite: Bool
    public var lastOpened: Date?
    public var live: LiveState

    public init(summary: ProjectSummary, favorite: Bool = false, lastOpened: Date? = nil, live: LiveState = .none) {
        self.summary = summary
        self.favorite = favorite
        self.lastOpened = lastOpened
        self.live = live
    }
}

/// The sections of the sidebar (design §6.1).
public enum LibrarySection: String, Codable, Sendable, CaseIterable {
    /// The projects folder and Other places, never the trash.
    case all
    /// Favourites that are not in the trash.
    case favorites
    /// Only what is outside the projects folder.
    case otherPlaces
    case trash
}

/// The order of the list (design §6.2).
public enum LibrarySort: String, Codable, Sendable, CaseIterable {
    case dateRecorded, name, duration, size, lastOpened
}

/// The groups of the grid when it is sorted by date (design §6.2).
public enum DateGroup: Equatable, Hashable, Sendable {
    case today, yesterday
    /// A day of this week, as `Calendar.component(.weekday, …)` numbers it.
    case weekday(Int)
    case month(year: Int, month: Int)

    /// The group's heading: "Hoy", "Ayer", "Martes", "Noviembre de 2026" (the first letter in capitals), in the
    /// calendar's locale.
    public func title(calendar: Calendar) -> String {
        let locale = calendar.locale ?? Locale.current
        switch self {
        case .today: return "Hoy"
        case .yesterday: return "Ayer"
        case .weekday(let weekday):
            let names = calendar.standaloneWeekdaySymbols
            guard (1...names.count).contains(weekday) else { return "" }
            return Self.capitalizingFirst(names[weekday - 1], locale)
        case .month(let year, let month):
            var parts = DateComponents()
            parts.year = year
            parts.month = month
            parts.day = 1
            guard let date = calendar.date(from: parts) else { return "" }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("MMMMy")
            return Self.capitalizingFirst(formatter.string(from: date), locale)
        }
    }

    private static func capitalizingFirst(_ text: String, _ locale: Locale) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased(with: locale) + text.dropFirst()
    }
}

/// What the library shows from the items it has: pure functions, nothing is read or written.
public enum LibraryListing {
    /// The items of `section` whose name or folder contain `search` (case and accents ignored, as Finder does), in the
    /// order asked. An empty search (or only spaces) keeps all. A project without the value that is sorted by (a take
    /// still recording has no length, a project that cannot be read no date, one never opened no last opening) goes last
    /// in either direction; ties go by name, ascending, and then by path, so the order never changes between calls.
    public static func items(
        _ all: [LibraryItem], section: LibrarySection, search: String, sort: LibrarySort, ascending: Bool
    ) -> [LibraryItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = all.filter { item in
            guard contains(item, in: section) else { return false }
            if query.isEmpty { return true }
            return item.summary.name.localizedStandardContains(query)
                || subfolder(item.summary).contains { $0.localizedStandardContains(query) }
        }
        return kept.sorted { lhs, rhs in
            if sort == .name {
                let byName = lhs.summary.name.localizedStandardCompare(rhs.summary.name)
                if byName != .orderedSame { return (byName == .orderedAscending) == ascending }
                return lhs.summary.path < rhs.summary.path
            }
            switch (key(lhs, sort), key(rhs, sort)) {
            case (nil, .some): return false  // a missing value goes last whichever way the list goes
            case (.some, nil): return true
            case (.some(let a), .some(let b)) where a != b: return ascending ? a < b : a > b
            default: return tieBreak(lhs, rhs)
            }
        }
    }

    /// How many items each section has (every section is a key).
    public static func counts(_ all: [LibraryItem]) -> [LibrarySection: Int] {
        var counts = Dictionary(uniqueKeysWithValues: LibrarySection.allCases.map { ($0, 0) })
        for item in all {
            for section in LibrarySection.allCases where contains(item, in: section) { counts[section, default: 0] += 1 }
        }
        return counts
    }

    /// `items`, which keep their order, in the groups of the grid: Today, Yesterday, the other days of this week
    /// (the calendar's week) and then by month. A project goes by when it was recorded, or, if that is not known, when
    /// the library last saw it; one dated after today (a clock that was wrong) goes in Today. The groups come in the
    /// order their first item has.
    public static func groups(_ items: [LibraryItem], now: Date, calendar: Calendar) -> [(group: DateGroup, items: [LibraryItem])] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        var result: [(group: DateGroup, items: [LibraryItem])] = []
        var index: [DateGroup: Int] = [:]
        for item in items {
            let date = item.summary.recordedAt ?? item.summary.lastSeen
            let group: DateGroup
            if date >= today {
                group = .today
            } else if date >= yesterday {
                group = .yesterday
            } else if let week, week.contains(date) {
                group = .weekday(calendar.component(.weekday, from: date))
            } else {
                let parts = calendar.dateComponents([.year, .month], from: date)
                group = .month(year: parts.year ?? 0, month: parts.month ?? 0)
            }
            if let at = index[group] {
                result[at].items.append(item)
            } else {
                index[group] = result.count
                result.append((group, [item]))
            }
        }
        return result
    }

    /// The components of the project's place: the folders below the projects folder (none for the folder itself; the
    /// app writes "Toma ▸ Clientes"), the folder that holds it for a project of Other places (one component, the whole
    /// path, as "/Volumes/Trabajo"), and none for the trash.
    public static func subfolder(_ summary: ProjectSummary) -> [String] {
        switch summary.place {
        case .projectsFolder(let subfolder): return subfolder.split(separator: "/").map(String.init)
        case .trash: return []
        case .elsewhere:
            let parent = (summary.path as NSString).deletingLastPathComponent
            return parent.isEmpty ? [] : [parent]
        }
    }

    // MARK: -

    private static func contains(_ item: LibraryItem, in section: LibrarySection) -> Bool {
        let place = item.summary.place
        switch section {
        case .all: return place != .trash
        case .favorites: return item.favorite && place != .trash
        case .otherPlaces: return place == .elsewhere
        case .trash: return place == .trash
        }
    }

    /// The value `sort` compares, `nil` if the project has none (never for the name, which is compared as text).
    private static func key(_ item: LibraryItem, _ sort: LibrarySort) -> Double? {
        switch sort {
        case .dateRecorded: return item.summary.recordedAt?.timeIntervalSince1970
        case .name: return 0
        case .duration: return item.summary.outputSeconds
        case .size: return item.summary.size.map(Double.init)
        case .lastOpened: return item.lastOpened?.timeIntervalSince1970
        }
    }

    private static func tieBreak(_ lhs: LibraryItem, _ rhs: LibraryItem) -> Bool {
        switch lhs.summary.name.localizedStandardCompare(rhs.summary.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.summary.path < rhs.summary.path
        }
    }
}
