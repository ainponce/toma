// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ProjectFormat
import Recovery
import os

/// Looks for takes a crash left open and offers to recover them. Never deletes anything: recovery closes
/// a take from what is on disk, and a project that cannot be read safely is only listed, untouched.
@MainActor
final class RecoveryPrompt {
    /// Called with the last project recovered.
    var recovered: (URL) -> Void = { _ in }

    private var isRunning = false
    private nonisolated static let logger = Logger(subsystem: "dev.toma.Toma", category: "Recovery")

    private struct Failure: Sendable {
        var package: ProjectPackage
        var takeID: String
        var error: any Error
    }

    /// Scans `folder`. At launch it only speaks up when there is something to recover; from the menu
    /// it also says when there is nothing.
    func run(in folder: URL, atLaunch: Bool) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let results = await Task.detached(priority: .userInitiated) { RecoveryScanner.scan(directory: folder) }.value
        var recoverable: [(package: ProjectPackage, takeID: String)] = []
        var needsRepair: [(package: ProjectPackage, reason: String)] = []
        for result in results {
            switch result {
            case let .recoverable(package, takeID): recoverable.append((package, takeID))
            case let .needsRepair(package, reason): needsRepair.append((package, reason))
            }
        }
        for (package, reason) in needsRepair {
            Self.logger.notice("Needs repair, left untouched: \(package.url.path, privacy: .public): \(reason, privacy: .public)")
        }

        guard !recoverable.isEmpty else {
            guard !atLaunch else { return }
            let alert = NSAlert()
            alert.messageText = String(localized: "No recordings need recovering.")
            alert.informativeText = Self.repairList(needsRepair)
            show(alert)
            return
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "We found \(recoverable.count) recordings that didn't finish saving. Recover them?")
        alert.informativeText = Self.repairList(needsRepair)
        alert.addButton(withTitle: String(localized: "Recover"))
        alert.addButton(withTitle: String(localized: "Later", comment: "Button: leave the unfinished recordings as they are for now"))
        guard show(alert) == .alertFirstButtonReturn else { return }

        let takes = recoverable
        let (closed, failures) = await Task.detached(priority: .userInitiated) { await Self.recover(takes) }.value
        if let last = closed.last { recovered(last.url) }
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

    /// The projects that cannot be read safely, one per line, or nothing.
    private static func repairList(_ needsRepair: [(package: ProjectPackage, reason: String)]) -> String {
        guard !needsRepair.isEmpty else { return "" }
        return String(localized: "These projects can't be read safely and were left untouched:")
            + "\n" + needsRepair.map { "• \($0.package.url.lastPathComponent): \($0.reason)" }.joined(separator: "\n")
    }

    @discardableResult
    private func show(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate()
        return alert.runModal()
    }
}
