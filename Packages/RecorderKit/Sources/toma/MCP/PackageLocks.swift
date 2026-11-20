// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Synchronization

/// A package by its folder's device and inode (the identity plan 4b decision 19 gives the control socket's), so two
/// paths to one package are one; by its path if its folder cannot be read.
struct PackageKey: Hashable, Sendable {
    private let device: Int64
    private let inode: UInt64
    private let path: String

    init(_ url: URL) {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
            path = ""
        } else {
            device = -1
            inode = 0
            path = url.standardizedFileURL.path
        }
    }

    /// The file an export writes at `url`, by its path (its folder's links resolved, in lower case, as APFS compares
    /// names by default): two exports to it go one at a time, as `MP4Exporter` and `GIFExporter` need (they would
    /// share the partial file). Never the key of a package.
    static func output(_ url: URL) -> PackageKey {
        let folder = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        return PackageKey(device: -2, inode: 0, path: (folder + "/" + url.lastPathComponent).lowercased())
    }

    private init(device: Int64, inode: UInt64, path: String) {
        self.device = device
        self.inode = inode
        self.path = path
    }
}

/// One line per package (`MCPContext.serialized`): a call takes a ticket (`reserve`), waits until it is the first of
/// its line (`wait`) and leaves it when done (`release`), so the calls on a package go one at a time, in the order of
/// their tickets. The server takes a call's ticket when it reads the call, before the call's task starts.
final class PackageLocks: Sendable {
    struct Ticket: Hashable, Sendable {
        let key: PackageKey
        let number: UInt64
    }

    /// The ticket the server took for a call, which the call's first `serialized` on that package uses.
    final class Reservation: Sendable {
        let ticket: Ticket
        private let taken = Mutex(false)

        init(_ ticket: Ticket) {
            self.ticket = ticket
        }

        /// The ticket, the first time it is asked for with its package; `nil` after, or for another package.
        func take(for key: PackageKey) -> Ticket? {
            guard ticket.key == key else { return nil }
            return takeIfUnused()
        }

        /// The ticket if nobody took it yet (the server releases it so when the call ends); `nil` after.
        func takeIfUnused() -> Ticket? {
            taken.withLock { taken in
                defer { taken = true }
                return taken ? nil : ticket
            }
        }
    }

    private struct Line {
        var tickets: [UInt64] = []
        /// The tickets waiting to be first, and how to tell them.
        var waiting: [UInt64: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state = Mutex((next: UInt64(0), lines: [PackageKey: Line]()))

    /// A new ticket, last in the line of `key`.
    func reserve(_ key: PackageKey) -> Ticket {
        state.withLock { state in
            let ticket = Ticket(key: key, number: state.next)
            state.next += 1
            state.lines[key, default: Line()].tickets.append(ticket.number)
            return ticket
        }
    }

    /// Returns once `ticket` is the first of its line. Throws `CancellationError`, the ticket out of the line, if the
    /// task is cancelled before, or if the ticket left the line already.
    func wait(_ ticket: Ticket) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let now: Result<Void, any Error>? = state.withLock { state in
                    guard let line = state.lines[ticket.key], line.tickets.contains(ticket.number) else {
                        return .failure(CancellationError())
                    }
                    if line.tickets.first == ticket.number { return .success(()) }
                    if Task.isCancelled {
                        // Not the first: nobody goes next because it leaves.
                        _ = Self.remove(ticket, from: &state.lines)
                        return .failure(CancellationError())
                    }
                    state.lines[ticket.key]?.waiting[ticket.number] = continuation
                    return nil
                }
                if let now { continuation.resume(with: now) }
            }
        } onCancel: {
            // Only a ticket still waiting leaves: one that is first already is its call's until it releases it.
            let waiter: CheckedContinuation<Void, any Error>? = state.withLock { state in
                guard let waiter = state.lines[ticket.key]?.waiting[ticket.number] else { return nil }
                // A ticket waiting is never the first.
                _ = Self.remove(ticket, from: &state.lines)
                return waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// `body` once `ticket` is first in its line (and the task is not cancelled), then `ticket` released, also when
    /// `body` or the wait throws. `body` may release it before it ends (an export, once it has read its project).
    func holding<T: Sendable>(_ ticket: Ticket, _ body: @Sendable () async throws -> T) async throws -> T {
        do {
            try await wait(ticket)
            try Task.checkCancellation()
            let value = try await body()
            release(ticket)
            return value
        } catch {
            release(ticket)
            throw error
        }
    }

    /// Takes `ticket` out of its line (its call is done, or never ran); the next one goes if it was first. Releasing a
    /// ticket twice does nothing.
    func release(_ ticket: Ticket) {
        let next: CheckedContinuation<Void, any Error>? = state.withLock { state in
            Self.remove(ticket, from: &state.lines)
        }
        next?.resume()
    }

    /// Takes `ticket` out of `lines`, and gives the first ticket's waiter when that ticket just became first.
    private static func remove(
        _ ticket: Ticket, from lines: inout [PackageKey: Line]
    ) -> CheckedContinuation<Void, any Error>? {
        guard var line = lines[ticket.key], let index = line.tickets.firstIndex(of: ticket.number) else { return nil }
        line.tickets.remove(at: index)
        line.waiting[ticket.number] = nil
        var next: CheckedContinuation<Void, any Error>?
        if index == 0, let first = line.tickets.first {
            next = line.waiting.removeValue(forKey: first)
        }
        lines[ticket.key] = line.tickets.isEmpty ? nil : line
        return next
    }
}
