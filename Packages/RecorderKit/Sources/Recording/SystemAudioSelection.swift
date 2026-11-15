// SPDX-License-Identifier: GPL-3.0-or-later
import CoreAudio
import Darwin
import ProjectFormat

/// Which apps' sound the `system-audio` track records.
public enum SystemAudioScope: Codable, Equatable, Sendable {
    /// Every app but Toma and the notification and alert sounds (`SystemAudioExclusions`).
    case all
    /// Only these apps, by bundle ID, with their helpers (`com.google.Chrome` takes `com.google.Chrome.helper`).
    case applications([String])
}

/// What system audio never records: notification and alert sounds. Alert sounds are played by
/// `systemsoundserverd`, a daemon started on demand (on macOS 26.6 its `CFBundleIdentifier` is
/// `systemsoundserverd` and its signing identifier `com.apple.systemsoundserverd`). A process matches by exact
/// equality of its bundle ID or of its executable's path.
public enum SystemAudioExclusions {
    public static let bundleIdentifiers = [
        "com.apple.notificationcenterui", "com.apple.UserNotificationCenter", "systemsoundserverd", "com.apple.systemsoundserverd",
    ]
    public static let executablePaths = ["/usr/sbin/systemsoundserverd", "/usr/sbin/usernoted"]

    /// Whether system audio never records `process`.
    public static func matches(_ process: AudioProcessInfo) -> Bool {
        process.bundleIdentifier.map(bundleIdentifiers.contains) == true
            || process.executablePath.map(executablePaths.contains) == true
    }
}

/// The processes a tap names, by their Core Audio process objects.
public enum TapTargets: Equatable, Sendable {
    /// Every process that plays audio but these.
    case allExcept([AudioObjectID])
    /// Only these processes.
    case only([AudioObjectID])
}

/// Which processes a system audio tap takes, and what the track says it records.
public enum SystemAudioSelection {
    /// `all` excludes this process (`ownObjectID`, or the listed process whose PID is `ownPID`) and every exclusion.
    /// `applications` takes the chosen apps and their helpers (bundle ID equal to a chosen one, or a chosen one
    /// followed by `.`), never an exclusion nor this process. While none of them runs, the tap needs a process
    /// that exists, so it names this one as a placeholder (`.only([ownObjectID])`, or `.only([])` without one),
    /// which `ProcessTapSource` records as silence (`isPlaceholder`): Toma's own sound is never recorded.
    public static func targets(
        scope: SystemAudioScope, processes: [AudioProcessInfo], ownPID: pid_t, ownObjectID: AudioObjectID?
    ) -> TapTargets {
        switch scope {
        case .all:
            let own = ownObjectID ?? processes.first { $0.pid == ownPID }?.objectID
            let excluded = processes.filter { $0.pid != ownPID && $0.objectID != own && SystemAudioExclusions.matches($0) }
            return .allExcept((own.map { [$0] } ?? []) + excluded.map(\.objectID))
        case .applications(let chosen):
            let taken = processes.filter { process in
                guard process.pid != ownPID, process.objectID != ownObjectID, !SystemAudioExclusions.matches(process),
                      let bundle = process.bundleIdentifier
                else { return false }
                return chosen.contains { bundle == $0 || bundle.hasPrefix($0 + ".") }
            }
            return taken.isEmpty ? placeholder(ownObjectID: ownObjectID) : .only(taken.map(\.objectID))
        }
    }

    /// Whether `a` and `b` name the same processes, in any order: only then does a running tap need no update.
    public static func sameTargets(_ a: TapTargets, _ b: TapTargets) -> Bool {
        switch (a, b) {
        case let (.allExcept(x), .allExcept(y)), let (.only(x), .only(y)): x.sorted() == y.sorted()
        default: false
        }
    }

    /// The bundle IDs a tap names on macOS 26 (`CATapDescription.bundleIDs`), so a process that starts mid-take,
    /// such as `systemsoundserverd`, is left out or taken from its first buffer. In `all` mode, the ones
    /// `trackSource` excludes. In `applications` mode, the chosen ones `trackSource` includes, followed by those of
    /// the processes `targets` takes that are not among them (a chosen app's helpers), in case `bundleIDs` replaces
    /// the process list instead of adding to it. The placeholder adds nothing: this process is never named.
    public static func tapBundleIDs(
        scope: SystemAudioScope, targets: TapTargets, processes: [AudioProcessInfo], ownPID: pid_t, ownBundleIdentifier: String?
    ) -> [String] {
        let source = trackSource(scope: scope, ownBundleIdentifier: ownBundleIdentifier)
        guard case .applications = scope else { return source.excludedBundleIDs ?? [] }
        var bundleIDs = source.includedBundleIDs ?? []
        guard case .only(let taken) = targets else { return bundleIDs }
        for process in processes where taken.contains(process.objectID) && process.pid != ownPID {
            guard let bundle = process.bundleIdentifier, bundle != ownBundleIdentifier, !bundleIDs.contains(bundle) else { continue }
            bundleIDs.append(bundle)
        }
        return bundleIDs
    }

    /// Whether `targets` is the placeholder of an `applications` scope none of whose apps runs.
    public static func isPlaceholder(_ targets: TapTargets, ownObjectID: AudioObjectID?) -> Bool {
        targets == placeholder(ownObjectID: ownObjectID)
    }

    /// What the track records: in `all` mode, every app but this one (when it has a bundle ID) and the exclusions;
    /// in `applications` mode, the chosen apps that can be recorded (neither this one nor an exclusion).
    public static func trackSource(scope: SystemAudioScope, ownBundleIdentifier: String?) -> TrackSource {
        switch scope {
        case .all:
            return TrackSource(
                name: "System Audio",
                excludedBundleIDs: (ownBundleIdentifier.map { [$0] } ?? []) + SystemAudioExclusions.bundleIdentifiers)
        case .applications(let chosen):
            let recordable = chosen.filter { $0 != ownBundleIdentifier && !SystemAudioExclusions.bundleIdentifiers.contains($0) }
            return TrackSource(name: "System Audio", includedBundleIDs: recordable)
        }
    }

    private static func placeholder(ownObjectID: AudioObjectID?) -> TapTargets {
        .only(ownObjectID.map { [$0] } ?? [])
    }
}
