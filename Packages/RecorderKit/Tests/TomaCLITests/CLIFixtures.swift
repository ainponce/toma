// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectAPI
import ProjectFormat
import RecorderKitTestSupport

/// What the tests of the `toma` command share: a project of 10 s of a screen and a microphone with two recorded markers
/// (at 3 s and 7 s), the `toma` that is built, run as a process with every `TOMA_*` variable in a temporary folder, and
/// the `APIEnvironment` of those folders.
enum CLIFixtures {
    static let base = HostTime(nanoseconds: 5_000_000_000_000)
    static let seconds = 10.0

    /// The `toma` built next to this test bundle (in the build's directory of products).
    static var executable: URL {
        get throws {
            let next = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "toma")
            // From this file: `.build/debug/toma`, should the bundle be somewhere else.
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            for candidate in [next, package.appending(path: ".build/debug/toma")]
            where FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            throw TestSupportError.missing("the built toma, next to \(next.path)")
        }
    }

    /// The `TOMA_*` variables of the folders of `dir`: none of the user's.
    static func variables(in dir: URL) -> [String: String] {
        [
            "TOMA_CACHES_ROOT": dir.appending(path: "Caches").path, "TOMA_MUSIC_ROOT": dir.appending(path: "Music").path,
            "TOMA_STYLES": dir.appending(path: "Styles").path, "TOMA_PROJECTS_FOLDER": dir.appending(path: "Projects").path,
            "TOMA_CONTROL_SOCKET": dir.appending(path: "control.sock").path,
        ]
    }

    /// The API's environment with the folders `toma` uses in `dir`.
    static func environment(in dir: URL) -> APIEnvironment {
        .standard(variables: variables(in: dir))
    }

    /// What a run of `toma` gave.
    struct Run: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String

        /// Standard output as the one JSON object it must be.
        func object() throws -> [String: Any] {
            try unwrap(try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any], "a JSON object in \(stdout)")
        }

        /// The `code` of `{"error": {"code", "message"}}` on standard output.
        var errorCode: String? {
            ((try? object())?["error"] as? [String: Any])?["code"] as? String
        }
    }

    /// Runs `toma` with `arguments` (and `input` on its standard input) in `dir`, with the variables of `dir`; its
    /// standard output and standard error go to files, so neither fills up a pipe.
    @concurrent static func toma(_ arguments: [String], in dir: URL, input: Data? = nil) async throws -> Run {
        let id = UUID().uuidString
        let out = dir.appending(path: "stdout-\(id)"), err = dir.appending(path: "stderr-\(id)")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.removeItem(at: err)
        }
        let process = Process()
        process.executableURL = try executable
        process.arguments = arguments
        process.currentDirectoryURL = dir
        process.environment = ProcessInfo.processInfo.environment.merging(variables(in: dir)) { $1 }
        process.standardOutput = try FileHandle(forWritingTo: out)
        process.standardError = try FileHandle(forWritingTo: err)
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            if let input {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        return Run(
            status: status, stdout: String(decoding: try Data(contentsOf: out), as: UTF8.self),
            stderr: String(decoding: try Data(contentsOf: err), as: UTF8.self))
    }

    /// A take of `seconds` of one display (10 fps) and a microphone, with `marker` events at 3 s and 7 s, in a new package
    /// `<name>.toma` in `dir`.
    @concurrent static func package(in dir: URL, name: String = "Fixture") async throws -> URL {
        let builder = try TakeBuilder(in: dir, name: name)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: seconds, framesPerSecond: 10, width: 320, height: 180)])
        try await builder.addAudioTrack(
            id: "mic", source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "mic"),
            segments: [AudioSegmentSpec(start: base, seconds: seconds)])
        try builder.addEvents(
            [InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))]
                + [3.0, 7.0].map { InputEvent(t: base.adding(seconds: $0), kind: .marker) })
        return try builder.write().package.url
    }
}

private final class BundleMarker {}
