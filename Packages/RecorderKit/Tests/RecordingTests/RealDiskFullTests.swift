// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import ProjectFormat
import SyntheticCapture
import Testing

@testable import Recording

extension RealTimeRecordingTests {
    /// Fills a real APFS volume (a 300 MB disk image) while recording, with the disk-space policy
    /// switched off, so the writers themselves run into `ENOSPC`. The take must still close cleanly,
    /// on disk too: the reserve it holds gives the room for the final writes.
    @Suite struct RealDiskFullTests {
        /// Space left for recording once the take's reserve is taken: filled in a few seconds.
        static let recordingRoomBytes: Int64 = 3_000_000

        @Test func realDiskFullClosesTakeCleanly() async throws {
            try await withTemporaryDirectory { directory in
                let image = directory.appending(path: "full.dmg")
                let volume = directory.appending(path: "volume", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: false)
                try hdiutil(["create", "-size", "300m", "-fs", "APFS", "-volname", "TomaDiskFull", image.path])
                try hdiutil(["attach", "-nobrowse", "-mountpoint", volume.path, image.path])
                defer { detach(volume) }

                let package = try ProjectPackage.create(
                    in: volume, name: "Full", app: AppInfo(name: "Tests", version: "0"), now: Date())
                try fill(volume, leaving: Int64(TakeReserve.size) + Self.recordingRoomBytes)
                var policy = DiskSpacePolicy()
                policy.minimumToStart = 0
                policy.warnBelow = 0
                policy.stopBelow = 0
                let writers = MadeWriters()
                let coordinator = RecordingCoordinator(
                    package: package,
                    sources: [SyntheticAudioSource(), SyntheticVideoSource(width: 1920, height: 1080, framesPerSecond: 60)],
                    input: NoInputRecorder(),
                    diskMonitor: DiskSpaceMonitor(volumeURL: volume, policy: policy, interval: .milliseconds(200)),
                    systemActivity: AsyncStream.makeStream(of: SystemActivity.self).stream,
                    writerFactory: { url, media in
                        let writer = try FragmentedTrackWriter(url: url, media: media)
                        writers.append(writer)
                        return writer
                    }
                )
                // Whatever fails below, the take is stopped before the volume goes away.
                let outcome = await Result { try await recordUntilFull(coordinator, package) }
                _ = try? await coordinator.stop()
                // Which shape of error AVFoundation gave the full disk, for when a run ends otherwise.
                for writer in writers.all {
                    guard let failure = writer.failure else { continue }
                    print("RealDiskFullTests: a writer failed with \(errorChain(failure))")
                }
                try outcome.get()
            }
        }

        private func recordUntilFull(_ coordinator: RecordingCoordinator, _ package: ProjectPackage) async throws {
            let warnings = WarningLog()
            let warningsDone = Task {
                for await warning in coordinator.warnings { warnings.append(warning) }
            }
            let (autoStops, autoStopped) = AsyncStream.makeStream(of: (TakeRecord, (any Error)?).self)
            await coordinator.setOnAutoStop { autoStopped.yield(($0, $1)) }
            let id = try await coordinator.start()
            let (record, failure) = try #require(await first(of: autoStops, within: .seconds(60)))

            #expect(failure == nil, "closing failed: \(String(describing: failure))")
            #expect(record.status == .complete)
            for track in record.tracks {
                #expect(!track.segments.isEmpty)
                for segment in track.segments {
                    #expect(segment.endReason == .diskFull)
                    #expect(segment.endHostTime != nil)
                    let duration = try await AVURLAsset(url: package.url.appending(path: segment.file)).load(.duration)
                    #expect(duration.seconds > 0.5, "\(segment.file) is not readable")
                }
            }
            // The take closed on disk too: the manifest says exactly what the record says.
            let manifest = try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
            #expect(manifest.takes.first { $0.id == id } == record)
            #expect(!RecordingLock.isHeld(at: package.lockURL(take: id)))
            #expect(!FileManager.default.fileExists(atPath: package.reserveURL(take: id).path))
            #expect(try await coordinator.stop() == record)
            await warningsDone.value
            #expect(warnings.all.contains(.stoppedForDiskSpace))
        }

        /// Fills the volume until a write fails with `ENOSPC` (the reported free space is larger than
        /// what APFS lets a file take), then gives `headroom` bytes back by truncating the filler.
        private func fill(_ volume: URL, leaving headroom: Int64) throws {
            let fd = open(volume.appending(path: "filler.bin").path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            let chunk = [UInt8](repeating: 0, count: 1 << 20)
            var size: off_t = 0
            while true {
                let written = chunk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if written > 0 {
                    size += off_t(written)
                } else if errno == ENOSPC {
                    break
                } else if errno != EINTR {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            guard fsync(fd) == 0, ftruncate(fd, max(0, size - off_t(headroom))) == 0, fsync(fd) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }
}

/// The writers a take made, read once it is closed: no writer is touched by its pipeline any more then.
private final class MadeWriters: @unchecked Sendable {
    private let lock = NSLock()
    private var writers: [FragmentedTrackWriter] = []

    var all: [FragmentedTrackWriter] { lock.withLock { writers } }

    func append(_ writer: FragmentedTrackWriter) {
        lock.withLock { writers.append(writer) }
    }
}

/// `error`, its user info and every error under it (`NSUnderlyingErrorKey`, `NSMultipleUnderlyingErrorsKey`).
private func errorChain(_ error: NSError, depth: Int = 0) -> String {
    let indent = String(repeating: "  ", count: depth)
    var text = "\n\(indent)\(error.domain) \(error.code) \(error.userInfo.filter { $0.key != NSUnderlyingErrorKey && $0.key != NSMultipleUnderlyingErrorsKey })"
    guard depth < 8 else { return text }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { text += errorChain(underlying, depth: depth + 1) }
    for underlying in error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] ?? [] { text += errorChain(underlying, depth: depth + 1) }
    return text
}

private struct HdiutilError: Error, CustomStringConvertible {
    var arguments: [String]
    var status: Int32
    var output: String
    var description: String { "hdiutil \(arguments.joined(separator: " ")) exited \(status): \(output)" }
}

@discardableResult
private func hdiutil(_ arguments: [String]) throws -> String {
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
    return output
}

/// Detaches the volume, forcing it if a plain detach fails, so no test leaves a volume mounted.
private func detach(_ volume: URL) {
    if (try? hdiutil(["detach", volume.path])) != nil { return }
    do {
        try hdiutil(["detach", "-force", volume.path])
    } catch {
        Issue.record("Could not detach \(volume.path): \(error)")
    }
}
