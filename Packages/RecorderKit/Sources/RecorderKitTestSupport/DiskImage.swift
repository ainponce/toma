// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A blank disk image attached at a folder of its own, for tests that need a volume of a given file system
/// or size. Detach it before the folder is removed.
public struct DiskImage: Sendable {
    public enum FileSystem: Sendable {
        /// exFAT has no `RENAME_EXCL` (`renamex_np` gives `ENOTSUP`).
        case apfs, hfsPlus, exFAT

        fileprivate var hdiutilName: String {
            switch self {
            case .apfs: "APFS"
            case .hfsPlus: "HFS+"
            case .exFAT: "ExFAT"
            }
        }
    }

    /// Where the volume is mounted, inside the folder given to `attach`.
    public let mountPoint: URL

    /// Creates a `sizeMegabytes` MB image of `fileSystem` in `directory` and mounts it (not shown in the
    /// Finder) at a new folder there.
    public static func attach(sizeMegabytes: Int, fileSystem: FileSystem, in directory: URL) throws -> DiskImage {
        let name = "DiskImage-\(UUID().uuidString)"
        let image = directory.appending(path: "\(name).dmg")
        let mountPoint = directory.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: false)
        try hdiutil(["create", "-size", "\(sizeMegabytes)m", "-fs", fileSystem.hdiutilName, "-volname", "TomaTest", image.path])
        try hdiutil(["attach", "-nobrowse", "-mountpoint", mountPoint.path, image.path])
        return DiskImage(mountPoint: mountPoint)
    }

    /// Unmounts the volume; with `force`, even while files on it are open.
    public func detach(force: Bool = false) throws {
        try hdiutil(force ? ["detach", "-force", mountPoint.path] : ["detach", mountPoint.path])
    }
}

private struct HdiutilError: Error, CustomStringConvertible {
    var arguments: [String]
    var status: Int32
    var output: String
    var description: String { "hdiutil \(arguments.joined(separator: " ")) exited \(status): \(output)" }
}

private func hdiutil(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw HdiutilError(arguments: arguments, status: process.terminationStatus, output: output)
    }
}
