// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// What the app says of its own projects (design §6.6), by package path: the one a take records into, the ones its
/// editors have open, and the ones found open in another app. Never found by probing a lock.
public struct LibraryLive: Equatable, Sendable {
    public var recordingPath: String?
    public var openHere: Set<String>
    public var openElsewhere: Set<String>

    public init(recordingPath: String? = nil, openHere: Set<String> = [], openElsewhere: Set<String> = []) {
        self.recordingPath = recordingPath
        self.openHere = openHere
        self.openElsewhere = openElsewhere
    }

    /// What the app adds to `summary`: recording into it first, then open here, then open in another app.
    public func state(of summary: ProjectSummary) -> LiveState {
        if let recordingPath, summary.path == recordingPath { return .recording }
        if openHere.contains(summary.path) { return .openHere }
        if openElsewhere.contains(summary.path) { return .openElsewhere }
        return .none
    }
}

/// What a batch of updates changed in a `LibraryCatalog`.
public struct LibraryChanges: Equatable, Sendable {
    /// A project was added, changed or removed: what is shown and the index change.
    public var projects = false
    /// The projects whose thumbnail may be another now (one not known before, or whose files, state or place changed):
    /// they are looked for again.
    public var thumbnails: Set<PackageIdentity> = []
    /// What the sidebar's foot or the strip say changed: the progress, a slow disk, the projects folder that cannot be
    /// read.
    public var status = false
    /// A walk of the projects folder ended.
    public var walkFinished = false

    public init(
        projects: Bool = false, thumbnails: Set<PackageIdentity> = [], status: Bool = false, walkFinished: Bool = false
    ) {
        self.projects = projects
        self.thumbnails = thumbnails
        self.status = status
        self.walkFinished = walkFinished
    }
}

/// One section of the grid: a date group when it is sorted by date, otherwise all the items with no heading.
public struct LibraryGroup: Equatable, Sendable {
    public var date: DateGroup?
    public var items: [LibraryItem]

    public init(date: DateGroup?, items: [LibraryItem]) {
        self.date = date
        self.items = items
    }
}

/// What the window shows of a section (design §6.1, §6.2).
public struct LibrarySections: Equatable, Sendable {
    /// How many items each section of the sidebar has.
    public var counts: [LibrarySection: Int]
    /// The items of the section that match the search, in order.
    public var shown: [LibraryItem]
    /// `shown` in the grid's sections.
    public var groups: [LibraryGroup]
    /// What the projects of the trash take, as far as their sizes are summed.
    public var trashBytes: Int64

    public init(counts: [LibrarySection: Int], shown: [LibraryItem], groups: [LibraryGroup], trashBytes: Int64) {
        self.counts = counts
        self.shown = shown
        self.groups = groups
        self.trashBytes = trashBytes
    }
}

/// What the library knows of its projects and of its walk, kept in step with a `LibraryScanner`'s updates (design §6.8,
/// §10): a value the window's model feeds and reads, nothing read or written here.
///
/// - A summary without an identity (file 0) is never kept; one the scanner did not know the thumbnail key of keeps the
///   key it had while its files look the same; one equal to what is known changes nothing.
/// - `.removed` drops only the summary: what is kept by identity elsewhere (favorites, where a project of the trash came
///   from) stays, since a `.summary` of the same identity may follow (a project moved during a walk).
/// - `.projectsFolderUnreadable` holds until a walk ends without saying it again (`.finished`); a walk started again
///   (`walkStarted()`) does not hide it before it ends.
public struct LibraryCatalog: Sendable {
    public private(set) var summaries: [PackageIdentity: ProjectSummary] = [:]
    /// There was no index, and the first walk is still finding projects: "Buscando proyectos… N".
    public private(set) var isLookingForProjects: Bool
    public private(set) var projectsFound = 0
    /// The disks that are slow to answer, by name, in the order they started to be.
    public private(set) var waitingFor: [String] = []
    /// The projects folder cannot be read, as the last walk or look found.
    public private(set) var isFolderUnreadable = false
    /// The walk of a `reconcile` ended.
    public private(set) var walkFinished = false
    /// A `.projectsFolderUnreadable` came since the walk began.
    private var unreadableThisWalk = false

    /// What the cached index knew; with none, the first walk is looking for projects.
    public init(index: LibraryIndex) {
        for summary in index.projects where summary.identity.file != 0 { summaries[summary.identity] = summary }
        isLookingForProjects = index.projects.isEmpty
    }

    /// A walk starts again ("Volver a intentar"): what it finds replaces what the last one said of the folder.
    public mutating func walkStarted() {
        unreadableThisWalk = false
        walkFinished = false
    }

    /// Applies `updates`, in order, and says what they changed.
    public mutating func apply(_ updates: [LibraryUpdate]) -> LibraryChanges {
        var changes = LibraryChanges()
        for update in updates {
            switch update {
            case .summary(var summary):
                guard summary.identity.file != 0 else { continue }
                let old = summaries[summary.identity]
                if summary.thumbnailKey == nil, let old, Self.sameFiles(old, summary) {
                    summary.thumbnailKey = old.thumbnailKey
                }
                guard summary != old else { continue }
                summaries[summary.identity] = summary
                changes.projects = true
                if old.map({ Self.mayLookDifferent($0, summary) }) ?? true { changes.thumbnails.insert(summary.identity) }
            case .removed(let identity):
                if summaries.removeValue(forKey: identity) != nil { changes.projects = true }
            case .progress(let found):
                if found != projectsFound {
                    projectsFound = found
                    changes.status = true
                }
            case .waiting(let volume):
                if !waitingFor.contains(volume) {
                    waitingFor.append(volume)
                    changes.status = true
                }
            case .waitingEnded(let volume):
                if waitingFor.contains(volume) {
                    waitingFor.removeAll { $0 == volume }
                    changes.status = true
                }
            case .projectsFolderUnreadable:
                unreadableThisWalk = true
                if !isFolderUnreadable {
                    isFolderUnreadable = true
                    changes.status = true
                }
            case .finished:
                walkFinished = true
                changes.walkFinished = true
                if isLookingForProjects || (isFolderUnreadable && !unreadableThisWalk) { changes.status = true }
                isLookingForProjects = false
                if !unreadableThisWalk { isFolderUnreadable = false }
                unreadableThisWalk = false
            }
        }
        return changes
    }

    /// Keeps `key` as the thumbnail key of the project `identity` (found on an action of the user); whether it changed.
    @discardableResult
    public mutating func setThumbnailKey(_ key: String, for identity: PackageIdentity) -> Bool {
        guard var summary = summaries[identity], summary.thumbnailKey != key else { return false }
        summary.thumbnailKey = key
        summaries[identity] = summary
        return true
    }

    // MARK: - What an action of the user changed, before the scanner looks again (design §6.3)

    /// The project `identity` was moved by an action of the user to `path` (renamed, to or from the trash), in `place`:
    /// shown there at once, its name the package's. Into the trash it is there since `now` (in whole seconds); out of
    /// it, a project like any other until the scanner reads it again; renamed, its state stays. Whether it changed.
    @discardableResult
    public mutating func move(_ identity: PackageIdentity, to path: String, place: Place, now: Date) -> Bool {
        guard var summary = summaries[identity] else { return false }
        summary.path = path
        summary.name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        summary.place = place
        if place == .trash {
            if case .inTrash = summary.state {} else { summary.state = .inTrash(since: now.roundedToWholeSeconds) }
        } else if case .inTrash = summary.state {
            summary.state = .normal
        }
        guard summary != summaries[identity] else { return false }
        summaries[identity] = summary
        return true
    }

    /// Takes the project `identity` out (deleted for good, taken out of the library) and returns what was known of it.
    @discardableResult
    public mutating func remove(_ identity: PackageIdentity) -> ProjectSummary? {
        summaries.removeValue(forKey: identity)
    }

    /// Puts back what `remove` took (an undo), unless something of the same identity is known again meanwhile (the
    /// scanner told it: what it told is newer). Whether it was put back. One without an identity is never kept.
    @discardableResult
    public mutating func putBack(_ summary: ProjectSummary) -> Bool {
        guard summary.identity.file != 0, summaries[summary.identity] == nil else { return false }
        summaries[summary.identity] = summary
        return true
    }

    /// What the window shows of `section`: every project with what `records` and the app (`live`) add, those of the
    /// section that match `search` in the order asked, in date groups when sorted by date (one group without a date
    /// otherwise, none when nothing is shown), the counts of every section and what the trash takes.
    public func sections(
        section: LibrarySection, search: String, sort: LibrarySort, ascending: Bool, records: LibraryRecords,
        live: LibraryLive, now: Date, calendar: Calendar
    ) -> LibrarySections {
        let all = summaries.values.map { summary in
            LibraryItem(
                summary: summary, favorite: records.favorites.contains(summary.identity.string),
                lastOpened: records.lastOpened[summary.identity.string], live: live.state(of: summary))
        }
        let shown = LibraryListing.items(all, section: section, search: search, sort: sort, ascending: ascending)
        let groups: [LibraryGroup]
        if sort == .dateRecorded {
            groups = LibraryListing.groups(shown, now: now, calendar: calendar).map { LibraryGroup(date: $0.group, items: $0.items) }
        } else {
            groups = shown.isEmpty ? [] : [LibraryGroup(date: nil, items: shown)]
        }
        let trashBytes = all.reduce(Int64(0)) { total, item in
            item.summary.place == .trash ? total + (item.summary.size ?? 0) : total
        }
        return LibrarySections(counts: LibraryListing.counts(all), shown: shown, groups: groups, trashBytes: trashBytes)
    }

    /// The files a thumbnail key is made of look the same.
    private static func sameFiles(_ a: ProjectSummary, _ b: ProjectSummary) -> Bool {
        a.manifest == b.manifest && a.edit == b.edit && a.log == b.log
    }

    /// Whether a new summary of the same project may show another thumbnail.
    private static func mayLookDifferent(_ a: ProjectSummary, _ b: ProjectSummary) -> Bool {
        !sameFiles(a, b) || a.state != b.state || a.path != b.path || a.place != b.place || a.thumbnailKey != b.thumbnailKey
    }
}
