// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// What the scanner found in one package.
public enum ScanResult: Sendable, Equatable {
    /// `takeID` is marked `recording` but nobody holds its lock: its recorder died. `TakeRecovery`
    /// can close it.
    case recoverable(package: ProjectPackage, takeID: String)
    /// The package cannot be read safely by this version (`reason` says why). Nothing in it is touched.
    case needsRepair(package: ProjectPackage, reason: String)
}

/// Finds takes left open by a crash. Read-only: it never changes a package.
public enum RecoveryScanner {
    /// Looks at every `*.toma` folder directly inside `directory` (not in subfolders), each on its
    /// own, in name order. A take marked `recording` whose `recording.lock` nobody holds is
    /// `recoverable`; one whose lock is held is being recorded and is skipped. A package whose
    /// manifest is missing or unreadable, or of a newer `formatVersion`, `needsRepair`; so does one
    /// with a path that could leave the package (`Manifest.validatePaths()`), or a symlink or an entry
    /// of the wrong kind inside a take (`ProjectPackage.checkLayout`), and then none of its takes is
    /// offered for recovery.
    ///
    /// Never throws because of a package; a `directory` that cannot be listed gives no results.
    public static func scan(directory: URL) -> [ScanResult] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names
            .filter { ($0 as NSString).pathExtension.lowercased() == ProjectPackage.fileExtension }
            .sorted()
            .compactMap { name -> URL? in
                let url = directory.appendingPathComponent(name, isDirectory: true)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
                else { return nil }
                return url
            }
            .flatMap { scan(package: ProjectPackage(url: $0)) }
    }

    private static func scan(package: ProjectPackage) -> [ScanResult] {
        let manifest: Manifest
        do {
            let data = try Data(contentsOf: package.manifestURL)
            // The version first: a newer manifest may not decode as this version's `Manifest`.
            let version = try Manifest.formatVersion(of: data)
            guard version <= Manifest.currentFormatVersion else {
                return [.needsRepair(
                    package: package, reason: "format version \(version) is newer than \(Manifest.currentFormatVersion)")]
            }
            manifest = try ProjectJSON.decoder().decode(Manifest.self, from: data)
        } catch {
            return [.needsRepair(package: package, reason: "manifest.json cannot be read: \(error.localizedDescription)")]
        }
        do throws(PackagePathError) {
            try manifest.validatePaths()
            for take in manifest.takes { try package.checkLayout(of: take) }
        } catch {
            return [.needsRepair(package: package, reason: error.description)]
        }
        return manifest.takes
            .filter { $0.status == .recording && !RecordingLock.isHeld(at: package.lockURL(take: $0.id)) }
            .map { .recoverable(package: package, takeID: $0.id) }
    }
}
