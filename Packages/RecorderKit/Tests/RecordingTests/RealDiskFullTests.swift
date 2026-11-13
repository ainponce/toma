// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import ProjectFormat
import SyntheticCapture
import Testing

@testable import Recording

/// Fills a real APFS volume (a 300 MB disk image) while recording, with the disk-space policy
/// switched off, so the writers themselves run into `ENOSPC`.
@Suite struct RealDiskFullTests {
    /// Space given back after filling the volume, so recording fills it in seconds, not minutes.
    static let headroomBytes: Int64 = 3_000_000

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
            try fill(volume, leaving: Self.headroomBytes)
            var policy = DiskSpacePolicy()
            policy.minimumToStart = 0
            policy.warnBelow = 0
            policy.stopBelow = 0
            let coordinator = RecordingCoordinator(
                package: package,
                sources: [SyntheticAudioSource(), SyntheticVideoSource(width: 1920, height: 1080, framesPerSecond: 60)],
                input: NoInputRecorder(),
                diskMonitor: DiskSpaceMonitor(volumeURL: volume, policy: policy, interval: .milliseconds(200)),
                systemActivity: AsyncStream.makeStream(of: SystemActivity.self).stream
            )
            let warnings = WarningLog()
            let warningsDone = Task {
                for await warning in coordinator.warnings { warnings.append(warning) }
            }
            let (autoStops, autoStopped) = AsyncStream.makeStream(of: TakeRecord.self)
            await coordinator.setOnAutoStop { autoStopped.yield($0) }
            let id = try await coordinator.start()
            let record = try #require(await first(of: autoStops, within: .seconds(60)))

            #expect(record.status == .complete)
            for track in record.tracks {
                #expect(!track.segments.isEmpty)
                #expect(track.segments.last?.endReason == .diskFull)
                for segment in track.segments {
                    #expect(segment.endHostTime != nil)
                    let duration = try await AVURLAsset(url: package.url.appending(path: segment.file)).load(.duration)
                    #expect(duration.seconds > 0.5, "\(segment.file) is not readable")
                }
            }
            #expect(!RecordingLock.isHeld(at: package.lockURL(take: id)))

            // The manifest on disk is whole and readable. With no space left, the final write may not
            // have fitted: then it still shows the take as recording, which recovery closes later.
            let manifest = try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
            let onDisk = try #require(manifest.takes.first { $0.id == id })
            #expect(onDisk == record || onDisk.status == .recording)
            do {
                #expect(try await coordinator.stop() == record)
            } catch {
                // The same outcome as the automatic stop: closing could not write the manifest or log.
                #expect(TrackPipeline.isDiskFull(error as NSError), "\(error)")
                #expect(onDisk.status == .recording)
            }
            await warningsDone.value
            #expect(warnings.all.contains(.stoppedForDiskSpace))
            #expect(warnings.all.contains { if case .writerFailed = $0 { true } else { false } })
        }
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
