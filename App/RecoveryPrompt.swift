// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import ProjectFormat
import Recovery
import os

/// Looks for takes a crash left open and offers to recover them. Never deletes anything: recovery closes
/// a take from what is on disk, and a project that cannot be read safely is only listed, untouched.
@MainActor
final class RecoveryPrompt {
    /// Called with every project recovered, in order, after the alert that lists them.
    var recovered: ([URL]) -> Void = { _ in }

    private var isRunning = false
    private let repairNotices = RepairNotices()
    private nonisolated static let logger = Logger(subsystem: "dev.toma.Toma", category: "Recovery")

    private struct Failure: Sendable {
        var package: ProjectPackage
        var takeID: String
        var error: any Error
    }

    /// Scans `folder`. At launch it only speaks up when there is something to recover, or a damaged project
    /// it has not mentioned before; from the menu it also says when there is nothing.
    func run(in folder: URL, atLaunch: Bool) async {
        await run(atLaunch: atLaunch, asking: true) { RecoveryScanner.scan(directory: folder) }
    }

    /// Scans the one package at `url` (the library's Recuperar, 1c design §6.6): what it has to recover is recovered
    /// without asking again, since that is what the user asked for; if there is nothing, it says so, as the menu does.
    func run(package url: URL) async {
        await run(atLaunch: false, asking: false) { RecoveryScanner.scan(package: ProjectPackage(url: url)) }
    }

    /// Scans with `scan`, off the main thread, and offers to recover what it found (`asking`), or recovers it at once.
    private func run(atLaunch: Bool, asking: Bool, scan: @escaping @Sendable () -> [ScanResult]) async {
        guard !isRunning else {
            if !atLaunch {
                let alert = NSAlert()
                alert.messageText = String(localized: "Recovery is already running.")
                show(alert)
            }
            return
        }
        isRunning = true
        defer { isRunning = false }

        let results = await Task.detached(priority: .userInitiated) { scan() }.value
        var recoverable: [(package: ProjectPackage, takeID: String)] = []
        var damaged: [RepairNotice] = []
        for result in results {
            switch result {
            case let .recoverable(package, takeID): recoverable.append((package, takeID))
            case let .needsRepair(package, reason): damaged.append(RepairNotice(path: package.url.path, reason: reason))
            }
        }
        for notice in damaged {
            Self.logger.notice("Needs repair, left untouched: \(notice.path, privacy: .public): \(notice.reason, privacy: .public)")
        }
        // At launch each damaged project is mentioned once; the menu lists them all.
        let mentioned = atLaunch ? repairNotices.unseen(damaged) : damaged

        guard !recoverable.isEmpty else {
            if !atLaunch {
                let alert = NSAlert()
                alert.messageText = String(localized: "No recordings need recovering.")
                alert.informativeText = Self.repairList(mentioned)
                show(alert)
            } else if !mentioned.isEmpty {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "Some projects can't be read safely")
                alert.informativeText = Self.repairList(mentioned)
                show(alert)
            }
            repairNotices.markShown(mentioned)
            return
        }

        var recovers = true
        if asking {
            let alert = NSAlert()
            alert.messageText = String(localized: "We found \(recoverable.count) recordings that didn't finish saving. Recover them?")
            alert.informativeText = Self.repairList(mentioned)
            alert.addButton(withTitle: String(localized: "Recover"))
            alert.addButton(withTitle: String(localized: "Later", comment: "Button: leave the unfinished recordings as they are for now"))
            recovers = show(alert) == .alertFirstButtonReturn
        }
        repairNotices.markShown(mentioned)
        guard recovers else { return }

        let takes = recoverable
        let (closed, failures) = await Task.detached(priority: .userInitiated) { await Self.recover(takes) }.value
        // A package with two recovered takes is one project.
        var seen: Set<URL> = []
        let projects = closed.map(\.url).filter { seen.insert($0.standardizedFileURL).inserted }
        if !projects.isEmpty {
            let done = NSAlert()
            done.messageText = String(localized: "Recovered \(projects.count) recordings")
            done.informativeText = projects.map { "• " + $0.deletingPathExtension().lastPathComponent }.joined(separator: "\n")
                + (projects.count > RecoveredProjects.maximumOpened
                    ? "\n\n" + String(localized: "The first \(RecoveredProjects.maximumOpened) open now; the others are in the projects folder.")
                    : "")
            done.addButton(withTitle: String(localized: "OK"))
            done.addButton(withTitle: String(localized: "Show in Finder"))
            if show(done) == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting(projects)
            }
            recovered(projects)
        }
        guard !failures.isEmpty else { return }
        let failed = NSAlert()
        failed.alertStyle = .warning
        failed.messageText = String(localized: "Couldn't recover \(failures.count) recordings")
        failed.informativeText = String(localized: "They were left as they are. To try again, use Recover Recordings… in the menu bar.")
            + "\n\n" + failures.map { "• \($0.package.url.lastPathComponent): \(userFacingDescription(of: $0.error))" }.joined(separator: "\n")
        show(failed)
    }

    /// Recovers the takes one at a time, as `TakeRecovery` requires.
    private nonisolated static func recover(
        _ takes: [(package: ProjectPackage, takeID: String)]
    ) async -> (closed: [ProjectPackage], failures: [Failure]) {
        var closed: [ProjectPackage] = []
        var failures: [Failure] = []
        for (package, takeID) in takes {
            do {
                let take = try await TakeRecovery.recover(package: package, takeID: takeID)
                logger.notice("Recovered \(take.id, privacy: .public) of \(package.url.path, privacy: .public)")
                closed.append(package)
            } catch {
                logger.error("Cannot recover \(takeID, privacy: .public) of \(package.url.path, privacy: .public): \(String(describing: error), privacy: .public)")
                failures.append(Failure(package: package, takeID: takeID, error: error))
            }
        }
        return (closed, failures)
    }

    /// The projects that cannot be read safely, one per line under a heading, or nothing. The reasons come
    /// from recovery, in English, and are shown as details.
    private static func repairList(_ notices: [RepairNotice]) -> String {
        guard !notices.isEmpty else { return "" }
        let lines = notices.map { notice in
            let name = (notice.path as NSString).lastPathComponent
            return "• " + String(localized: "\(name) (details: \(notice.reason))", comment: "A damaged project: its name, and recovery's technical reason")
        }
        return String(localized: "These projects can't be read safely and were left untouched:")
            + "\n" + lines.joined(separator: "\n")
    }

    @discardableResult
    private func show(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        return alert.runModal()
    }
}
