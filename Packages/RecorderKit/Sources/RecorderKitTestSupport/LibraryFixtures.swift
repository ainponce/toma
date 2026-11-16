// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import ProjectFormat

/// Folders of projects of every kind the library meets (1c design §6.6), for its tests. Every package with a take has
/// the take `take-001` of `TakeBuilder`, of one display recorded for 1 s at 10 fps, unless its kind says otherwise.
public enum LibraryFixtures {
    public enum FixtureKind: Sendable {
        /// `v1.toma`: a package of format version 1, without edits.
        case v1
        /// `v2.toma`: a package of format version 2 with a camera track, without edits.
        case v2
        /// `v3.toma`: a package of format version 3 whose edit log keeps the first half second, in 9:16.
        case v3
        /// `from1b.toma`: a project of 1b (`DocumentV1Fixture`, two steps, no snapshot): its document of version 1.
        case from1b
        /// `unfinished.toma`: a take still `recording`, its segment open, as a crash leaves it.
        case unfinished
        /// `needs-repair.toma`: a manifest that is not JSON.
        case needsRepair
        /// `linked.toma`: a link to a package of format version 3 in the hidden folder `.targets/`.
        case symlinkedPackage
        /// `fifo-manifest.toma`: its `manifest.json` is a FIFO.
        case fifoManifest
        /// `huge-manifest.toma`: a whole manifest of format version 3, padded with spaces to 5 MiB.
        case hugeManifest
        /// `fifo-events.toma`: the take's `events.jsonl` is a FIFO.
        case fifoEvents
        /// `linked-events.toma`: the take's `events.jsonl` is a link to its whole event log, moved to `.targets/`.
        case symlinkedEvents
        /// `Synthetic 0001.toma`…: small packages of format version 3 written directly, without media nor events (the
        /// manifest names a segment that is not there) and with an edit log of the legacy document, to read many fast.
        /// Package *n* lasts *(n − 1) mod 60 + 1* s.
        case synthetic(count: Int)
    }

    /// The take every fixture with a take has.
    public static let take = "take-001"

    /// Writes a package of each of `kinds` into `dir`, in order, and returns their URLs, as the library lists them (a
    /// folder's with a `/` at its end, a link's without). The name of a kind that comes again gets « 2», « 3»…
    @concurrent public static func folder(in dir: URL, kinds: [FixtureKind]) async throws -> [URL] {
        var names = Set<String>()
        func free(_ base: String) -> String {
            var name = base
            var number = 1
            while names.contains(name) {
                number += 1
                name = "\(base) \(number)"
            }
            names.insert(name)
            return name
        }
        var urls: [URL] = []
        for kind in kinds {
            switch kind {
            case .v1:
                urls.append(try await display(in: dir, name: free("v1"), formatVersion: 1).package.url)
            case .v2:
                urls.append(try await display(in: dir, name: free("v2"), formatVersion: 2, camera: true).package.url)
            case .v3:
                let project = try await display(in: dir, name: free("v3"))
                var document = EditDocument.legacy(for: project)
                document.logSequence = 1
                document.aspect = .portrait
                document.sequence[0].end = document.sequence[0].start.adding(seconds: 0.5)
                let line = try EditLogEntry.create(seq: 1, document: document, app: app).jsonLine()
                try DurableFile.writeAtomically(Data((line + "\n").utf8), to: project.package.editLogURL)
                urls.append(project.package.url)
            case .from1b:
                // Made apart, then named as asked.
                let staging = try hiddenFolder(in: dir, name: ".staging-\(UUID().uuidString)")
                let made = try await DocumentV1Fixture.make(in: staging, steps: 2, snapshotAt: nil)
                let url = packageURL(in: dir, name: free("from1b"))
                try FileManager.default.moveItem(at: made, to: url)
                try FileManager.default.removeItem(at: staging)
                urls.append(url)
            case .unfinished:
                urls.append(try await display(in: dir, name: free("unfinished"), status: .recording).package.url)
            case .needsRepair:
                let url = try emptyPackage(in: dir, name: free("needs-repair"))
                try Data("{ this is not a manifest".utf8).write(to: ProjectPackage(url: url).manifestURL)
                urls.append(url)
            case .symlinkedPackage:
                let targets = try hiddenFolder(in: dir, name: ".targets")
                let target = try await display(in: targets, name: UUID().uuidString)
                let link = dir.appending(path: "\(free("linked")).\(ProjectPackage.fileExtension)", directoryHint: .notDirectory)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target.package.url)
                urls.append(link)
            case .fifoManifest:
                let url = try emptyPackage(in: dir, name: free("fifo-manifest"))
                try makeFIFO(at: ProjectPackage(url: url).manifestURL)
                urls.append(url)
            case .hugeManifest:
                let project = try await display(in: dir, name: free("huge-manifest"))
                var data = try SafeRead.regularFile(at: project.package.manifestURL)
                data.append(Data(repeating: UInt8(ascii: " "), count: 5 * 1_048_576 - data.count))
                try data.write(to: project.package.manifestURL)
                urls.append(project.package.url)
            case .fifoEvents:
                let project = try await display(in: dir, name: free("fifo-events"))
                let events = project.package.eventsURL(take: take)
                try FileManager.default.removeItem(at: events)
                try makeFIFO(at: events)
                urls.append(project.package.url)
            case .symlinkedEvents:
                let project = try await display(in: dir, name: free("linked-events"))
                let events = project.package.eventsURL(take: take)
                let targets = try hiddenFolder(in: dir, name: ".targets")
                let moved = targets.appending(path: "\(UUID().uuidString)-events.jsonl", directoryHint: .notDirectory)
                try FileManager.default.moveItem(at: events, to: moved)
                try FileManager.default.createSymbolicLink(at: events, withDestinationURL: moved)
                urls.append(project.package.url)
            case .synthetic(let count):
                for number in stride(from: 1, through: count, by: 1) {
                    urls.append(try synthetic(in: dir, name: free("Synthetic \(String(format: "%04d", number))"), number: number))
                }
            }
        }
        return urls
    }

    // MARK: - Private

    private static let app = AppInfo(name: "Toma", version: "0.3.0")
    private static let frame = Rect(x: 0, y: 0, width: 640, height: 360)

    /// A package of `TakeBuilder` with a take of one display for 1 s at 10 fps (and, with `camera`, a camera as long),
    /// written with `status`.
    private static func display(
        in dir: URL, name: String, formatVersion: Int = Manifest.currentFormatVersion, camera: Bool = false,
        status: TakeStatus = .complete
    ) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: name, formatVersion: formatVersion)
        let base = HostTime(nanoseconds: 5_000_000_000_000)
        let open = status == .recording
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10, endReason: open ? nil : .stopped)])
        if camera {
            try await builder.addVideoTrack(
                id: "camera-1", kind: .camera, source: TrackSource(name: "Synthetic Camera", deviceUniqueID: "camera-1"),
                segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10, width: 320, height: 180)])
        }
        try builder.addEvents([
            InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))
        ])
        return try builder.write(status: status)
    }

    /// Package *number* of `.synthetic`, written with plain writes: a take of one display whose segment is not there,
    /// and the edit log of its legacy document.
    private static func synthetic(in dir: URL, name: String, number: Int) throws -> URL {
        let url = try emptyPackage(in: dir, name: name)
        let package = ProjectPackage(url: url)
        let start = HostTime(nanoseconds: 5_000_000_000_000)
        let segment = package.segmentURL(take: take, track: "display-1", index: 1)
        let record = TakeRecord(
            id: take, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            tracks: [
                TrackRecord(
                    id: "display-1", kind: .display,
                    source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
                    segments: [
                        SegmentRecord(
                            index: 1, file: "takes/\(take)/display-1/\(segment.lastPathComponent)", startHostTime: start,
                            endHostTime: start.adding(seconds: Double((number - 1) % 60 + 1)), endReason: .stopped,
                            droppedFrames: 0, heartbeatFrames: 0)
                    ])
            ])
        let manifest = Manifest(
            formatVersion: Manifest.currentFormatVersion, app: app,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(number)), takes: [record],
            projectID: ProjectID.random())
        try ProjectJSON.encoder().encode(manifest).write(to: package.manifestURL)
        var document = EditDocument.legacy(take: record, events: [])
        document.logSequence = 1
        let line = try EditLogEntry.create(seq: 1, document: document, app: app).jsonLine()
        try Data((line + "\n").utf8).write(to: package.editLogURL)
        return url
    }

    /// `<dir>/<name>.toma`, as `ProjectPackage.create` names it, with nothing in it.
    private static func emptyPackage(in dir: URL, name: String) throws -> URL {
        let url = packageURL(in: dir, name: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private static func packageURL(in dir: URL, name: String) -> URL {
        dir.appendingPathComponent("\(name).\(ProjectPackage.fileExtension)", isDirectory: true)
    }

    /// `<dir>/<name>`, made if it is not there.
    private static func hiddenFolder(in dir: URL, name: String) throws -> URL {
        let url = dir.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeFIFO(at url: URL) throws {
        guard mkfifo(url.path, 0o644) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
