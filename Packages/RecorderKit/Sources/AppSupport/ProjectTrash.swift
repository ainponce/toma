// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

public enum ProjectTrashError: Error, Equatable {
    /// A take of the project holds its recording lock: it is being recorded.
    case takeStillRecording
}

/// Where a restarted take goes: `<projects folder>/Trash/`, a folder of whole projects that open like
/// any other, kept until the user deletes them. Nothing here ever deletes or replaces anything.
public enum ProjectTrash {
    public static let folderName = "Trash"

    /// `<projectsFolder>/Trash/`.
    public static func folder(in projectsFolder: URL) -> URL {
        projectsFolder.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Moves `package` into the trash of `projectsFolder`, creating the trash if needed, and returns where
    /// it is now: under its own name, with ` 2`, ` 3`, … added while a project of that name is in the
    /// trash. The trash is inside the projects folder, so this is a rename on the same volume: the project
    /// is never copied, nor left half in each place.
    ///
    /// Throws `takeStillRecording`, moving nothing, if any take folder of the package holds its recording
    /// lock. Any other failure is thrown, and leaves the package where it was.
    public static func move(_ package: ProjectPackage, projectsFolder: URL) throws -> URL {
        let takes = try FileManager.default.contentsOfDirectory(atPath: package.takesURL.path)
        guard !takes.contains(where: { RecordingLock.isHeld(at: package.lockURL(take: $0)) }) else {
            throw ProjectTrashError.takeStillRecording
        }
        let trash = folder(in: projectsFolder)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let base = package.url.deletingPathExtension().lastPathComponent
        var attempt = 1
        while true {
            let name = attempt == 1 ? base : "\(base) \(attempt)"
            let destination = trash.appendingPathComponent("\(name).\(ProjectPackage.fileExtension)", isDirectory: true)
            do {
                try FileManager.default.moveItem(at: package.url, to: destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                attempt += 1
            }
        }
    }
}
