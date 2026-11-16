// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// What the user asks the library to do with projects (design §6.3–§6.5), from the menus, the keys, a card's buttons and
/// VoiceOver.
public enum LibraryCommand: Hashable, Sendable {
    case open
    /// Edits the card's name: with its field, `rename` follows.
    case startRenaming
    case rename(String)
    case duplicate
    /// "Duplicar como": a copy whose first edit is this format (decision 35).
    case duplicateAs(Aspect)
    case showInFinder
    /// "." and the star: out of the favorites if they all are, otherwise into them.
    case toggleFavorite
    case setFavorite(Bool)
    case moveToTrash
    /// Only Other places: the file stays where it is.
    case removeFromLibrary
    case restore
    /// A take that did not finish saving: 1b's recovery on its package.
    case recover
    /// The trash's projects asked for, after an alert.
    case deleteNow
    /// Every project of the trash, after an alert.
    case emptyTrash
    /// Other places: looked at again ("Actualizar", design §6.5).
    case refresh
    /// Packages dropped on the window: those of the projects folder are shown, the others go to Other places.
    case addProjects([URL])
    case undo
    case redo
}

/// One entry of a project's menu (design §6.3).
public enum LibraryMenuEntry: Hashable, Sendable {
    case command(LibraryCommand)
    /// "Duplicar como ▸" with these formats: all but the project's own.
    case duplicateAs([Aspect])
    case divider
}

/// Which projects each command reaches and what a project's menu offers (design §6.3, §6.4, §6.6, §11): pure functions
/// of what the library shows.
public enum LibraryActionRules {
    /// Whether `command` reaches `item`, whose card is `busy` with an action of its own. What moves a package, or would
    /// copy or rename one being moved, never reaches a busy card ("que no se repite"); opening it, showing it in the Finder,
    /// the favorites and looking at it again do. Nothing of the trash but restoring, deleting and opening it (to look at)
    /// and showing it; Other places only for removing from the library and "Actualizar".
    public static func reaches(_ command: LibraryCommand, _ item: LibraryItem, busy: Bool) -> Bool {
        let place = item.summary.place
        switch command {
        case .open, .showInFinder: return true
        case .toggleFavorite, .setFavorite: return place != .trash
        case .refresh: return place == .elsewhere
        case .startRenaming, .rename, .duplicate, .moveToTrash: return !busy && place != .trash
        case .duplicateAs: return !busy && place != .trash && opens(item.summary.state)
        case .removeFromLibrary: return !busy && place == .elsewhere
        case .restore, .deleteNow, .emptyTrash: return !busy && place == .trash
        case .recover: return !busy && item.summary.state == .unfinished && item.live != .recording
        case .addProjects, .undo, .redo: return false
        }
    }

    /// What a menu offers for `items` (the selection, or the card under the pointer): in the trash, Abrir, Restaurar,
    /// Mostrar en Finder and Eliminar ahora…; elsewhere Abrir (Recuperar for a take that did not finish saving),
    /// Renombrar and Duplicar como for one project, Duplicar, Mostrar en Finder, Favoritos, Actualizar for Other places,
    /// then Mover a la papelera, or Quitar de la biblioteca for Other places.
    public static func entries(for items: [LibraryItem]) -> [LibraryMenuEntry] {
        guard !items.isEmpty else { return [] }
        let one = items.count == 1 ? items.first : nil
        if items.allSatisfy({ $0.summary.place == .trash }) {
            return [.command(.open), .command(.restore), .command(.showInFinder), .divider, .command(.deleteNow)]
        }
        var entries: [LibraryMenuEntry] = []
        if let one, reaches(.recover, one, busy: false) {
            entries.append(.command(.recover))
        } else {
            entries.append(.command(.open))
        }
        if one != nil { entries.append(.command(.startRenaming)) }
        entries.append(.command(.duplicate))
        if let one, reaches(.duplicateAs(.portrait), one, busy: false) {
            entries.append(.duplicateAs([Aspect.landscape, .portrait, .square].filter { $0 != one.summary.aspect }))
        }
        entries.append(.command(.showInFinder))
        entries.append(.command(.toggleFavorite))
        let elsewhere = items.contains { $0.summary.place == .elsewhere }
        if elsewhere { entries.append(.command(.refresh)) }
        entries.append(.divider)
        if items.contains(where: { $0.summary.place != .elsewhere }) { entries.append(.command(.moveToTrash)) }
        if elsewhere { entries.append(.command(.removeFromLibrary)) }
        return entries
    }

    /// The commands of `entries(for:)` for one card, its VoiceOver actions (design §11), "Duplicar como" aside.
    public static func accessibilityCommands(for item: LibraryItem) -> [LibraryCommand] {
        entries(for: [item]).compactMap { entry in
            if case .command(let command) = entry { return command }
            return nil
        }
    }

    /// What the button over a card's thumbnail offers while the pointer is over it (design §6.4, §6.6): Restaurar in the
    /// trash, Recuperar for a take that did not finish saving; nothing on a busy card.
    public static func hoverCommand(for item: LibraryItem, busy: Bool) -> LibraryCommand? {
        if reaches(.restore, item, busy: busy) { return .restore }
        if reaches(.recover, item, busy: busy) { return .recover }
        return nil
    }

    /// Whether a project in `state` opens in the editor, so it can get another format.
    public static func opens(_ state: ProjectState) -> Bool {
        switch state {
        case .normal, .readOnlyVolume: true
        case .unfinished, .needsRepair, .newerVersion, .inTrash, .unavailable: false
        }
    }
}

// MARK: - What the library tells

/// What an action of the library was doing when it failed.
public enum LibraryDoing: Hashable, Sendable {
    case rename, duplicate, moveToTrash, restore, delete
    /// "Duplicar como"'s first edit, on the copy.
    case changeFormat
}

/// Why an action failed, after "No se pudo … «…»:" (design §10).
public enum LibraryReason: Hashable, Sendable {
    /// It is not in the trash any more (restoring, deleting).
    case noLongerInTrash
    /// It is not there.
    case notThere
    /// Its editor has changes it could not write.
    case unsavedChanges
    case nameTaken
    case nameTooLong
    /// A name the user may not give (it was not typed: a copy's).
    case nameUnusable
    case noPermission
    case diskFull
    case readOnly
    case diskFailed
    case diskDidNotAnswer
    case link
    /// The copy could not be opened to change its format.
    case copyCannotBeOpened
    /// The copy could not be edited (read-only, another app took it).
    case copyCannotBeEdited
    /// The copy's edit could not be written.
    case editNotSaved
    /// Anything else the disk refused.
    case other
}

/// What the library tells the user after an action (design §10, §12), as typed values: the app says them in words.
public enum LibraryMessage: Hashable, Sendable {
    /// "Se está grabando."
    case recording
    /// "No se puede: está abierto en otra app."
    case openElsewhere
    /// "No se puede deshacer: la copia se abrió o cambió desde que se hizo."
    case copyOpenedOrChanged
    /// "No hay lugar para duplicarlo: hacen falta …"
    case noRoom(needed: Int64)
    /// "No se pudieron eliminar N proyectos: siguen en la papelera."
    case notDeleted(count: Int)
    /// One of Other places is not moved to the trash: "«…» está fuera de la carpeta de Toma: quitarlo de la biblioteca
    /// deja el archivo donde está."
    case outsideTomasFolder(name: String)
    /// "No se pudo … «name»: reason."
    case couldNot(LibraryDoing, name: String, LibraryReason)
    /// A package dropped on the window that the library never lists.
    case notListed(name: String, NotListed)

    /// What a `LibraryFailure` of `doing`, on the project `name`, tells. The text of Other places is only for one of
    /// Other places (`isElsewhere`): `.outsideProjectsFolder` of anything else means it is not where it was, and of a
    /// restore or a deletion that it is not in the trash any more.
    public static func of(_ failure: LibraryFailure, doing: LibraryDoing, name: String, isElsewhere: Bool) -> LibraryMessage {
        switch failure {
        case .recording: return .recording
        case .openElsewhere: return .openElsewhere
        case .copyOpenedOrChanged: return .copyOpenedOrChanged
        case .noRoom(let needed): return .noRoom(needed: needed)
        case .someNotDeleted(let count): return .notDeleted(count: count)
        case .outsideProjectsFolder:
            switch doing {
            case .moveToTrash where isElsewhere: return .outsideTomasFolder(name: name)
            case .restore, .delete: return .couldNot(doing, name: name, .noLongerInTrash)
            default: return .couldNot(doing, name: name, .notThere)
            }
        case .unsavedChanges: return .couldNot(doing, name: name, .unsavedChanges)
        case .name(let problem): return .couldNot(doing, name: name, reason(problem))
        case .posix(let code): return .couldNot(doing, name: name, reason(code))
        }
    }

    /// What deleting `names` for good tells when it failed: one project by its name, several by how many.
    public static func ofDeletion(_ failure: LibraryFailure, names: [String]) -> LibraryMessage {
        switch failure {
        case .recording, .openElsewhere, .someNotDeleted:
            return of(failure, doing: .delete, name: names.first ?? "", isElsewhere: false)
        case .outsideProjectsFolder, .posix:
            guard names.count == 1 else { return .notDeleted(count: names.count) }
            return of(failure, doing: .delete, name: names[0], isElsewhere: false)
        case .unsavedChanges, .name, .noRoom, .copyOpenedOrChanged:
            return .notDeleted(count: names.count)
        }
    }

    private static func reason(_ problem: NameProblem) -> LibraryReason {
        switch problem {
        case .taken: .nameTaken
        case .tooLong: .nameTooLong
        case .empty, .slashOrColon, .leadingDot, .controlCharacter: .nameUnusable
        }
    }

    private static func reason(_ code: POSIXErrorCode) -> LibraryReason {
        switch code {
        case .ENOENT, .ENOTDIR: .notThere
        case .EACCES, .EPERM: .noPermission
        case .ENOSPC, .EDQUOT: .diskFull
        case .EROFS: .readOnly
        case .EIO: .diskFailed
        case .ETIMEDOUT: .diskDidNotAnswer
        case .ELOOP: .link
        case .ENAMETOOLONG: .nameTooLong
        case .EEXIST: .nameTaken
        default: .other
        }
    }
}
