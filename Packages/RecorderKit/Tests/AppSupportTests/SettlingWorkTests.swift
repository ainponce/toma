// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import RecorderKitTestSupport
import Synchronization
import Testing

/// The export sheet's GIF preview and estimate run as `SettlingWork` (1c design §7.3): the first options at once, each
/// change after it settles, a change cancelling the work before it, and the sheet's end stopping it and freeing the sheet's
/// model.
@MainActor @Suite struct SettlingWorkTests {
    /// What the work and the waits did, in order.
    final class Events: Sendable {
        private let events = Mutex<[String]>([])
        var all: [String] { events.withLock { $0 } }
        func add(_ event: String) { events.withLock { $0.append(event) } }
    }

    /// Work that starts, waits until it is cancelled (or a minute), and says which.
    private static func longWork(_ events: Events) -> @MainActor (Int) async -> Void {
        { request in
            events.add("start \(request)")
            do {
                try await Task.sleep(for: .seconds(60))
                events.add("end \(request)")
            } catch {
                events.add("cancelled \(request)")
            }
        }
    }

    @Test func theFirstOptionsRunAtOnceAndEachChangeAfterItSettles() async {
        let events = Events()
        let work = SettlingWork<Int>(settle: .milliseconds(300)) { duration in events.add("wait \(duration)") }
        work.run(for: 1) { events.add("run \($0)") }
        #expect(await eventually { events.all.contains("run 1") })
        work.run(for: 2) { events.add("run \($0)") }
        #expect(await eventually { events.all.contains("run 2") })
        #expect(events.all == ["run 1", "wait 0.3 seconds", "run 2"])
    }

    @Test func aChangeCancelsTheWorkForTheOptionsBefore() async {
        let events = Events()
        let work = SettlingWork<Int>(settle: .milliseconds(300)) { _ in }
        work.run(for: 1, Self.longWork(events))
        #expect(await eventually { events.all == ["start 1"] })
        work.run(for: 2, Self.longWork(events))
        // The work for 1 notices its cancellation on the main actor, before or after the work for 2 starts.
        #expect(await eventually { Set(events.all) == ["start 1", "cancelled 1", "start 2"] })
        // No options (an MP4, or a range shorter than a frame): the work goes, and none starts.
        work.run(for: nil, Self.longWork(events))
        #expect(await eventually { events.all.contains("cancelled 2") })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(events.all.count == 4 && Set(events.all) == ["start 1", "cancelled 1", "start 2", "cancelled 2"])
        work.stop()
    }

    @Test func aChangeWhileWaitingForTheOptionsToSettleRunsOnlyTheLast() async {
        let events = Events()
        // Waits that last until they are cancelled.
        let work = SettlingWork<Int>(settle: .milliseconds(300)) { _ in
            events.add("wait")
            do { try await Task.sleep(for: .seconds(60)) } catch {
                events.add("wait cancelled")
                throw error
            }
        }
        work.run(for: 1) { events.add("run \($0)") }
        #expect(await eventually { events.all == ["run 1"] })
        work.run(for: 2) { events.add("run \($0)") }
        #expect(await eventually { events.all == ["run 1", "wait"] })
        work.run(for: 3) { events.add("run \($0)") }
        #expect(await eventually { events.all.filter { $0 == "wait cancelled" }.count == 1 && events.all.filter { $0 == "wait" }.count == 2 })
        work.stop()
        #expect(await eventually { events.all.filter { $0 == "wait cancelled" }.count == 2 })
        // Neither 2 nor 3 ran: 2 was replaced while it waited, and 3 was stopped.
        #expect(!events.all.contains("run 2") && !events.all.contains("run 3"))
    }

    /// The sheet's model holds its work, which holds the model weakly: stopping the work as the sheet ends cancels what
    /// is under way, and the model is freed as soon as the work notices, with what it holds (the project, its package's
    /// open folder).
    @Test func stoppingCancelsTheWorkAndFreesItsOwner() async {
        @MainActor final class Owner {
            let work = SettlingWork<Int>(settle: .milliseconds(300))
            let events: Events
            init(events: Events) { self.events = events }
            func start() {
                work.run(for: 1) { [weak self] request in await self?.make(request) }
            }
            private func make(_ request: Int) async {
                await SettlingWorkTests.longWork(events)(request)
            }
        }

        let events = Events()
        weak var freed: Owner?
        do {
            let owner = Owner(events: events)
            freed = owner
            owner.start()
            #expect(await eventually { events.all == ["start 1"] })
            owner.work.stop()
            #expect(owner.work.isStopped)
        }
        #expect(await eventually { freed == nil })
        #expect(events.all == ["start 1", "cancelled 1"])
    }

    @Test func nothingRunsOnceStopped() async {
        let events = Events()
        let work = SettlingWork<Int>(settle: .zero) { _ in }
        work.stop()
        work.run(for: 1) { events.add("run \($0)") }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(events.all.isEmpty)
    }
}
