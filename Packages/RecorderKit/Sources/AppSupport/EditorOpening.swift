// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Foundation
import ProjectFormat

/// How an editor opens the package at a URL (1c decision 36 and design §6.4), looked at off the main thread: first
/// whether it is in the trash of the projects folder, then whether its take is still marked as being recorded. A project
/// in the trash is only looked at: its session opens for viewing only (`EditContext.forcedReadOnly`), and a take there
/// that did not finish saving is offered to be restored first, never recovered (recovery writes into the package, and
/// emptying the trash would delete it).
public enum EditorOpening: Equatable, Sendable {
    /// The take `takeID` is still marked as being recorded (a crash, or a take being recorded): not opened, since opening
    /// a version 3 project writes its document. Out of the trash it is offered for recovery; in it, for Restore.
    case unfinished(takeID: String, inTrash: Bool)
    /// An edit session, for viewing only with this reason (`.inTrash`), or editable with none.
    case session(forcedReadOnly: ReadOnlyReason?)

    /// Whether the package is in the trash, as this opening found it.
    public var isInTrash: Bool {
        switch self {
        case .unfinished(_, let inTrash): inTrash
        case .session(let forced): forced == .inTrash
        }
    }

    /// How the package at `url` opens, its take `take` (the last one when `nil`), with `projectsFolder`'s trash. Reads the
    /// disk: never on the main thread.
    public static func of(_ url: URL, take: String?, projectsFolder: URL) -> EditorOpening {
        let inTrash = ProjectTrash.contains(url, projectsFolder: projectsFolder)
        if let unfinished = unfinishedTake(at: url, take: take) { return .unfinished(takeID: unfinished, inTrash: inTrash) }
        return .session(forcedReadOnly: inTrash ? .inTrash : nil)
    }

    /// Whether a take of the package at `url` may be recovered now: never while it is in the trash, wherever that was
    /// found from (it is restored first). Reads the disk: never on the main thread.
    public static func mayRecover(_ url: URL, projectsFolder: URL) -> Bool {
        !ProjectTrash.contains(url, projectsFolder: projectsFolder)
    }

    /// A take still marked as being recorded, by the package's manifest: the take asked for, or the last one.
    private static func unfinishedTake(at url: URL, take: String?) -> String? {
        guard let data = try? SafeRead.regularFile(at: ProjectPackage(url: url).manifestURL),
            let manifest = try? ProjectJSON.decoder().decode(Manifest.self, from: data)
        else { return nil }
        let record = take.map { id in manifest.takes.first { $0.id == id } } ?? manifest.takes.last
        return record?.status == .recording ? record?.id : nil
    }
}
