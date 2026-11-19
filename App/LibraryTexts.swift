// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Library
import ProjectFormat

/// What the library says of a project in words, for the cards, the list and VoiceOver (design §6.6, §11, §12). The
/// library's modules have no words: the codes and reasons they give are said here.
enum LibraryTexts {
    /// "Abierto": a project this app has open ("Open" is also the action, "Abrir").
    static var openHere: String {
        String(localized: "Open (library state)", defaultValue: "Open", comment: "The library: a project this app has open")
    }

    static var recording: String {
        String(localized: "Recording (library state)", defaultValue: "Recording", comment: "The library: a project being recorded")
    }

    /// The short state over the thumbnail and in the list's Status column; `nil` for a project with none to show.
    static func badge(_ item: LibraryItem) -> String? {
        switch item.live {
        case .recording: return recording
        case .openElsewhere: return String(localized: "Open in Another App", comment: "The library: a project another app has open")
        case .openHere, .none: break
        }
        switch item.summary.state {
        case .unfinished: return String(localized: "Unfinished", comment: "The library: a take that did not finish saving")
        case .needsRepair: return String(localized: "Can't Be Opened", comment: "The library: a project to repair")
        case .newerVersion:
            return String(localized: "Needs a Newer Version of Toma", comment: "The library: a project of a newer version")
        case .unavailable: return String(localized: "Not Available", comment: "The library: a project of Other places not found")
        case .normal, .readOnlyVolume, .inTrash: return nil
        }
    }

    /// The list's Status column: the badge, or that it is open here or read-only.
    static func status(_ item: LibraryItem) -> String {
        if let badge = badge(item) { return badge }
        if item.live == .openHere { return openHere }
        if case .readOnlyVolume = item.summary.state {
            return String(localized: "Read-Only", comment: "The library: a project on a disk that cannot be written")
        }
        return ""
    }

    /// Whether the card is dimmed: a project of Other places that was not found.
    static func isDimmed(_ item: LibraryItem) -> Bool {
        if case .unavailable = item.summary.state { return true }
        return false
    }

    /// The card's help: why it cannot be opened or is not available, that it is open here, when one of Other places was
    /// last seen; `nil` for none.
    static func help(_ item: LibraryItem) -> String? {
        if item.live == .openHere { return openHere }
        switch item.summary.state {
        case .needsRepair(let reason): return repairReason(reason)
        case .unavailable(.diskNotConnected(let disk)):
            return String(localized: "Disk “\(disk)” isn't connected.", comment: "The library: a project of Other places")
        case .unavailable(.notFound):
            return String(localized: "The project can't be found.", comment: "The library: a project of Other places")
        default: break
        }
        if item.summary.place == .elsewhere {
            let date = item.summary.lastSeen.formatted(.dateTime.day().month(.wide))
            return String(localized: "Last seen \(date)", comment: "The library: when a project of Other places was last looked at")
        }
        return nil
    }

    /// "14:32 · 16:9" under the name: the time it was recorded (with the day when the grid is not in sections by date)
    /// and its format; in the trash, since when it is there.
    static func subtitle(_ item: LibraryItem, timeOnly: Bool) -> String {
        if case .inTrash(let since) = item.summary.state {
            let date = since.formatted(.dateTime.day().month(.wide))
            return String(localized: "In the trash since \(date)", comment: "The library: when a project went to the trash")
        }
        var parts: [String] = []
        if let recorded = item.summary.recordedAt {
            parts.append(
                timeOnly ? recorded.formatted(date: .omitted, time: .shortened) : recorded.formatted(date: .abbreviated, time: .shortened))
        }
        if let aspect = item.summary.aspect { parts.append(aspectText(aspect)) }
        return parts.joined(separator: " · ")
    }

    /// A project's format as the library shows it: the ratio, or «Como la grabación» for `auto` (phase 2 design §6.4).
    static func aspectText(_ aspect: Aspect) -> String {
        aspect == .auto
            ? String(localized: "Like the Recording", comment: "The editor toolbar: the Format menu, the proportion of the recording; and the library, Duplicate As")
            : aspect.rawValue
    }

    /// The card for VoiceOver (design §11): "Demo nueva función, 2 minutos 14 segundos, 16:9, grabado hoy a las 14:32,
    /// favorito", and its state.
    static func accessibilityLabel(_ item: LibraryItem) -> String {
        var parts = [item.summary.name]
        if let seconds = item.summary.outputSeconds, item.live != .recording {
            let whole = Int(seconds.isFinite ? max(seconds, 0) : 0)
            parts.append(Duration.seconds(whole).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)))
        }
        if let aspect = item.summary.aspect { parts.append(aspectText(aspect)) }
        if let recorded = item.summary.recordedAt { parts.append(recordedPhrase(recorded)) }
        if item.favorite { parts.append(String(localized: "favorite", comment: "VoiceOver: a project of the library is a favorite")) }
        if let badge = badge(item) {
            parts.append(badge)
        } else if item.live == .openHere {
            parts.append(openHere)
        }
        if case .inTrash = item.summary.state { parts.append(subtitle(item, timeOnly: true)) }
        return parts.joined(separator: ", ")
    }

    /// "grabado hoy a las 14:32", "grabado ayer a las 9:58", "grabado el 12 de noviembre de 2026".
    private static func recordedPhrase(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) {
            return String(localized: "recorded today at \(time)", comment: "VoiceOver: when a project of the library was recorded")
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "recorded yesterday at \(time)", comment: "VoiceOver: when a project of the library was recorded")
        }
        let day = date.formatted(date: .long, time: .omitted)
        return String(localized: "recorded on \(day)", comment: "VoiceOver: when a project of the library was recorded")
    }

    /// Where the project is, for the list's Location column: "Toma", "Toma ▸ Clientes", "/Volumes/Trabajo", or the trash.
    static func location(_ item: LibraryItem, projectsFolderName: String) -> String {
        switch item.summary.place {
        case .projectsFolder:
            return ([projectsFolderName] + LibraryListing.subfolder(item.summary)).joined(separator: " ▸ ")
        case .trash:
            return projectsFolderName + " ▸ " + String(localized: "Trash", comment: "The library: the section of the trash")
        case .elsewhere:
            return LibraryListing.subfolder(item.summary).first.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
        }
    }

    // MARK: - Why a project cannot be opened

    /// Why `ProjectReader` found a project to repair, in the user's words: which part could not be read and why.
    static func repairReason(_ reason: RepairReason) -> String {
        switch reason.problem {
        case .isALink:
            return String(localized: "The project is a link.", comment: "The library: why a project can't be opened")
        case .notAFolder:
            return String(localized: "The project isn't a folder.", comment: "The library: why a project can't be opened")
        case .unknownFormat:
            return String(
                localized: "This version of Toma doesn't know the project's format.", comment: "The library: why a project can't be opened")
        default:
            break
        }
        let what: String
        switch reason.part {
        case .manifest: what = "manifest.json"
        case .package: what = String(localized: "the project", comment: "The library: what of a project can't be read")
        case .edit:
            what = String(localized: "the edit", comment: "The library: what of a project can't be read (its document or its log)")
        }
        guard let cause = cause(of: reason.problem) else {
            return String(localized: "Can't read \(what).", comment: "The library: why a project can't be opened")
        }
        return String(localized: "Can't read \(what): \(cause).", comment: "The library: why a project can't be opened, and the cause")
    }

    /// What went wrong, in a few words; `nil` for what has none to say.
    private static func cause(of problem: RepairReason.Problem) -> String? {
        switch problem {
        case .unreadable:
            return String(localized: "it's damaged or of another version", comment: "The library: why a part of a project can't be read")
        case .pathLeavesThePackage:
            return String(localized: "a path in it leaves the project", comment: "The library: why a part of a project can't be read")
        case .missingTake:
            return String(localized: "a recording is missing", comment: "The library: why a part of a project can't be read")
        case .system(let code):
            return cause(ofCode: code)
        case .isALink, .notAFolder, .unknownFormat, .other:
            return nil
        }
    }

    /// The system's refusal, by its code.
    private static func cause(ofCode code: Int32) -> String? {
        switch code {
        case ENOENT, ENOTDIR:
            String(localized: "it isn't there", comment: "The library: why a part of a project can't be read")
        case EACCES, EPERM:
            String(localized: "there's no permission", comment: "The library: why a part of a project can't be read")
        case EIO:
            String(localized: "the disk failed", comment: "The library: why a part of a project can't be read")
        case ETIMEDOUT:
            String(localized: "the disk didn't answer", comment: "The library: why a part of a project can't be read")
        case EFBIG:
            String(localized: "it's too large", comment: "The library: why a part of a project can't be read")
        case ELOOP:
            String(localized: "it's a link", comment: "The library: why a part of a project can't be read")
        case EFTYPE:
            String(localized: "it isn't a regular file", comment: "The library: why a part of a project can't be read")
        default:
            nil
        }
    }
}
