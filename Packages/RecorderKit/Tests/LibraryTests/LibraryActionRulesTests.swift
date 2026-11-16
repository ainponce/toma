// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Library
import ProjectFormat
import Testing

private func item(
    _ file: UInt64, place: Place = .projectsFolder(subfolder: ""), state: ProjectState = .normal, aspect: Aspect? = .landscape,
    favorite: Bool = false, live: LiveState = .none
) -> LibraryItem {
    let summary = ProjectSummary(
        identity: PackageIdentity(volume: "V", file: file), path: "/p/\(file).toma", name: "\(file)", place: place,
        aspect: aspect, hasCamera: false, state: state, lastSeen: Date(timeIntervalSince1970: 1_794_000_000))
    return LibraryItem(summary: summary, favorite: favorite, live: live)
}

@Suite struct LibraryActionRulesTests {
    /// Which cards a command reaches (design §6.3, §6.4): what moves a package never a busy card; opening, the Finder,
    /// the favorites and looking again do. The trash only restores, deletes, opens and shows.
    @Test func aCommandReachesOnlyTheCardsItMay() {
        let normal = item(1), trashed = item(2, place: .trash, state: .inTrash(since: Date())), elsewhere = item(3, place: .elsewhere)
        let unfinished = item(4, state: .unfinished), recording = item(5, state: .unfinished, live: .recording)
        func reaches(_ command: LibraryCommand, _ item: LibraryItem, busy: Bool = false) -> Bool {
            LibraryActionRules.reaches(command, item, busy: busy)
        }
        // A busy card: only what does not move it.
        for command in [LibraryCommand.open, .showInFinder, .toggleFavorite, .setFavorite(true)] {
            #expect(reaches(command, normal, busy: true), "\(command)")
        }
        for command in [LibraryCommand.rename("x"), .startRenaming, .duplicate, .duplicateAs(.portrait), .moveToTrash] {
            #expect(!reaches(command, normal, busy: true), "\(command)")
            #expect(reaches(command, normal), "\(command)")
        }
        // The trash: ⌘D and "." do nothing there; restoring and deleting only there.
        for command in [LibraryCommand.duplicate, .toggleFavorite, .setFavorite(true), .rename("x"), .moveToTrash, .duplicateAs(.square)] {
            #expect(!reaches(command, trashed), "\(command)")
        }
        for command in [LibraryCommand.restore, .deleteNow, .emptyTrash, .open, .showInFinder] {
            #expect(reaches(command, trashed), "\(command)")
            #expect(command == .open || command == .showInFinder || !reaches(command, normal), "\(command)")
        }
        #expect(!reaches(.restore, trashed, busy: true))
        // Other places.
        #expect(reaches(.removeFromLibrary, elsewhere) && !reaches(.removeFromLibrary, normal))
        #expect(reaches(.refresh, elsewhere) && !reaches(.refresh, normal))
        #expect(reaches(.moveToTrash, elsewhere), "it tells why it is not moved to the trash")
        // Recuperar: a take that did not finish saving, not one being recorded.
        #expect(reaches(.recover, unfinished) && !reaches(.recover, recording) && !reaches(.recover, normal))
        #expect(!reaches(.duplicateAs(.portrait), unfinished), "it does not open")
    }

    @Test func theMenusOfEachSection() {
        let trashed = item(2, place: .trash, state: .inTrash(since: Date()))
        #expect(
            LibraryActionRules.entries(for: [trashed])
                == [.command(.open), .command(.restore), .command(.showInFinder), .divider, .command(.deleteNow)])
        #expect(
            LibraryActionRules.entries(for: [item(1, aspect: .portrait)]) == [
                .command(.open), .command(.startRenaming), .command(.duplicate), .duplicateAs([.landscape, .square]),
                .command(.showInFinder), .command(.toggleFavorite), .divider, .command(.moveToTrash),
            ])
        #expect(
            LibraryActionRules.entries(for: [item(1), item(3, place: .elsewhere)]) == [
                .command(.open), .command(.duplicate), .command(.showInFinder), .command(.toggleFavorite), .command(.refresh),
                .divider, .command(.moveToTrash), .command(.removeFromLibrary),
            ])
        #expect(LibraryActionRules.entries(for: [item(4, state: .unfinished)]).first == .command(.recover))
        #expect(LibraryActionRules.accessibilityCommands(for: trashed) == [.open, .restore, .showInFinder, .deleteNow])
        #expect(LibraryActionRules.hoverCommand(for: trashed, busy: false) == .restore)
        #expect(LibraryActionRules.hoverCommand(for: trashed, busy: true) == nil)
        #expect(LibraryActionRules.hoverCommand(for: item(4, state: .unfinished), busy: false) == .recover)
        #expect(LibraryActionRules.hoverCommand(for: item(1), busy: false) == nil)
        #expect(LibraryActionRules.entries(for: []).isEmpty)
    }

    /// Which failure tells what (design §10): the text of Other places only for one of Other places; a restore or a
    /// deletion never says "fuera de la carpeta".
    @Test func whichFailureTellsWhat() {
        func of(_ failure: LibraryFailure, _ doing: LibraryDoing, elsewhere: Bool = false) -> LibraryMessage {
            LibraryMessage.of(failure, doing: doing, name: "Demo", isElsewhere: elsewhere)
        }
        #expect(of(.outsideProjectsFolder, .moveToTrash, elsewhere: true) == .outsideTomasFolder(name: "Demo"))
        #expect(of(.outsideProjectsFolder, .moveToTrash) == .couldNot(.moveToTrash, name: "Demo", .notThere))
        #expect(of(.outsideProjectsFolder, .restore) == .couldNot(.restore, name: "Demo", .noLongerInTrash))
        #expect(of(.outsideProjectsFolder, .restore, elsewhere: true) == .couldNot(.restore, name: "Demo", .noLongerInTrash))
        #expect(of(.recording, .rename) == .recording)
        #expect(of(.openElsewhere, .moveToTrash) == .openElsewhere)
        #expect(of(.copyOpenedOrChanged, .moveToTrash) == .copyOpenedOrChanged)
        #expect(of(.noRoom(needed: 7), .duplicate) == .noRoom(needed: 7))
        #expect(of(.name(.taken), .rename) == .couldNot(.rename, name: "Demo", .nameTaken))
        #expect(of(.name(.tooLong), .duplicate) == .couldNot(.duplicate, name: "Demo", .nameTooLong))
        #expect(of(.posix(.ENOSPC), .duplicate) == .couldNot(.duplicate, name: "Demo", .diskFull))
        #expect(of(.posix(.EROFS), .rename) == .couldNot(.rename, name: "Demo", .readOnly))
        #expect(of(.posix(.EXDEV), .rename) == .couldNot(.rename, name: "Demo", .other))
        #expect(of(.unsavedChanges, .moveToTrash) == .couldNot(.moveToTrash, name: "Demo", .unsavedChanges))

        #expect(LibraryMessage.ofDeletion(.outsideProjectsFolder, names: ["A"]) == .couldNot(.delete, name: "A", .noLongerInTrash))
        #expect(LibraryMessage.ofDeletion(.outsideProjectsFolder, names: ["A", "B"]) == .notDeleted(count: 2))
        #expect(LibraryMessage.ofDeletion(.someNotDeleted(1), names: ["A", "B"]) == .notDeleted(count: 1))
        #expect(LibraryMessage.ofDeletion(.openElsewhere, names: ["A"]) == .openElsewhere)
        #expect(LibraryMessage.ofDeletion(.posix(.EIO), names: ["A"]) == .couldNot(.delete, name: "A", .diskFailed))
    }

    /// Where a package is for the library, by the walk's rules (design §6.2): the one rule the app's actions use.
    @Test func whereAPackageIs() {
        let projects = URL(filePath: "/Users/me/Movies/Toma", directoryHint: .isDirectory)
        func at(_ path: String) -> PackageLocation {
            LibraryScanner.location(of: URL(filePath: path, directoryHint: .isDirectory), projectsFolder: projects)
        }
        #expect(at("/Users/me/Movies/Toma/Demo.toma") == .listed(.projectsFolder(subfolder: "")))
        #expect(at("/Users/me/Movies/Toma/a/b/c/d/Demo.toma") == .listed(.projectsFolder(subfolder: "a/b/c/d")))
        #expect(at("/Users/me/Movies/Toma/a/b/c/d/e/Demo.toma") == .notListed(.tooDeep))
        #expect(at("/Users/me/Movies/Toma/Trash/Demo.toma") == .listed(.trash))
        #expect(at("/Users/me/Movies/Toma/trash/Demo.toma") == .listed(.trash), "as the volume takes it")
        #expect(at("/Users/me/Movies/Toma/Trash/old/Demo.toma") == .notListed(.inTrashFolder))
        #expect(at("/Users/me/Movies/Toma/.hidden/Demo.toma") == .notListed(.hidden))
        #expect(at("/Users/me/Movies/Toma/Other.toma/Demo.toma") == .notListed(.insidePackage))
        #expect(at("/Users/me/Desktop/Demo.toma") == .elsewhere)
        #expect(at("/Users/me/Movies/Toma Old/Demo.toma") == .elsewhere, "a folder whose name starts the same is another")
        #expect(at("/Users/me/Movies/Toma/../Elsewhere/Demo.toma") == .elsewhere)
    }
}
