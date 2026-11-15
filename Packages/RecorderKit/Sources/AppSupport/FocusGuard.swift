// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os

/// Turns Do Not Disturb on around a take with a shortcut of the user's, and off once the take ends, also after the app
/// ended in the middle (spec §13, "No Molestar"). The shortcut gets the input `on` or `off`; it answers `changedOutput` to
/// `on` only if it turned Do Not Disturb on, and only then is it turned off again: one the user had on stays on. Every
/// run waits for the one before, so the shortcut never runs twice at once.
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

    /// Runs `identifier` with `on`, if a shortcut is chosen. `false` if it failed or did not end in time: nothing is left
    /// to turn off, and the take goes on without Do Not Disturb.
    public func takeWillStart(shortcut identifier: String?) async -> Bool {
        guard let identifier else { return true }
        return await inTurn { [self] in
            defaults.set(identifier, forKey: Self.activeKey)
            do {
                let output = try await runner.run(shortcut: identifier, input: "on")
                // Anything else: Do Not Disturb was on already, and stays on after the take.
                if output != Self.changedOutput { defaults.removeObject(forKey: Self.activeKey) }
                return true
            } catch {
                Self.logger.error("The Do Not Disturb shortcut did not run: \(String(describing: error), privacy: .public)")
                defaults.removeObject(forKey: Self.activeKey)
                return false
            }
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

    private func turnOffIfTurnedOn() async {
        await inTurn { [self] in
            guard let identifier = defaults.string(forKey: Self.activeKey) else { return }
            do {
                _ = try await runner.run(shortcut: identifier, input: "off")
            } catch {
                Self.logger.error("The Do Not Disturb shortcut did not turn it off: \(String(describing: error), privacy: .public)")
            }
            defaults.removeObject(forKey: Self.activeKey)
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
