// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

/// Turns Do Not Disturb on around a take with a shortcut of the user's, and off once the take ends, also after the app
/// ended in the middle (spec §13, "No Molestar"). The shortcut gets the input `on` or `off`; it answers `changedOutput` to
/// `on` only if it turned Do Not Disturb on, and only then is it turned off again: one the user had on stays on. Every
/// run waits for the one before, so the shortcut never runs twice at once. Until an `off` has run, the mark that it is
/// owed stays: an `off` that failed is run again when the next take ends or the app launches again, and so is the one
/// of an `on` that did not end in time (it may still turn Do Not Disturb on).
@MainActor
public final class FocusGuard {
    /// The identifier of the shortcut that turned Do Not Disturb on and has to turn it off: saved before it runs, so an
    /// end of the app in the middle of the take still turns it off (`recoverAfterLaunch`).
    public nonisolated static let activeKey = "focusShortcutActive"
    /// What the shortcut answers when it turned Do Not Disturb on.
    public nonisolated static let changedOutput = "changed"

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Focus")

    private let runner: any ShortcutRunning
    private let defaults: UserDefaults
    /// The last run asked for: the next one waits for it.
    private var lastRun: Task<Void, Never>?

    public init(runner: any ShortcutRunning, defaults: UserDefaults = .standard) {
        self.runner = runner
        self.defaults = defaults
    }

    /// Runs `identifier` with `on`, if a shortcut is chosen. `false` if it failed or did not end in time: the take goes
    /// on without Do Not Disturb. One that failed left nothing to turn off; one that did not end in time keeps its mark,
    /// so the take's end turns it off. An `off` still owed from before (it failed) stays owed whatever `on` does.
    public func takeWillStart(shortcut identifier: String?) async -> Bool {
        guard let identifier else { return true }
        return await inTurn { [self] in
            let owed = defaults.string(forKey: Self.activeKey)
            defaults.set(identifier, forKey: Self.activeKey)
            let ran: Bool
            /// Whether this run may have turned Do Not Disturb on.
            let mayHaveTurnedOn: Bool
            do {
                // Anything but `changedOutput`: Do Not Disturb was on already, and stays on after the take.
                mayHaveTurnedOn = try await runner.run(shortcut: identifier, input: "on") == Self.changedOutput
                ran = true
            } catch ShortcutsCLIError.timedOut {
                Self.logger.error("The Do Not Disturb shortcut did not end in time: it is turned off when the take ends")
                mayHaveTurnedOn = true
                ran = false
            } catch {
                Self.logger.error("The Do Not Disturb shortcut did not run: \(String(describing: error), privacy: .public)")
                mayHaveTurnedOn = false
                ran = false
            }
            // Nothing turned on this time: only an `off` owed from before remains.
            if !mayHaveTurnedOn {
                if let owed { defaults.set(owed, forKey: Self.activeKey) } else { defaults.removeObject(forKey: Self.activeKey) }
            }
            return ran
        }
    }

    /// Turns Do Not Disturb off, if the take turned it on.
    public func takeDidEnd() async {
        await turnOffIfTurnedOn()
    }

    /// Turns Do Not Disturb off, if a take turned it on and the app ended before it could.
    public func recoverAfterLaunch() async {
        await turnOffIfTurnedOn()
    }

    /// The mark goes once `off` has run; one that failed keeps it, for the next try.
    private func turnOffIfTurnedOn() async {
        await inTurn { [self] in
            guard let identifier = defaults.string(forKey: Self.activeKey) else { return }
            do {
                _ = try await runner.run(shortcut: identifier, input: "off")
                defaults.removeObject(forKey: Self.activeKey)
            } catch {
                Self.logger.error(
                    "The Do Not Disturb shortcut did not turn it off, it is tried again later: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Runs `body` once the runs asked for before it have ended.
    private func inTurn<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = lastRun
        let run = Task {
            await previous?.value
            return await body()
        }
        lastRun = Task { _ = await run.value }
        return await run.value
    }
}
