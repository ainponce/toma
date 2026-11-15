// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ProjectFormat
import Synchronization

/// Writes a `displayGeometry` event for each recorded display whose frame or scale changes during a take (a new
/// resolution, a new arrangement), heard from `CGDisplayRegisterReconfigurationCallback` once each reconfiguration
/// ends. The coordinator writes the first one of each display. A display that is gone writes nothing (its track
/// follows the restart policy). Nothing is written while paused; what changed meanwhile is written on `resume()`.
///
/// `query` gives a display's frame (global points) and the pixels per point its track records: `liveQuery` gives
/// the display's own, as at `CaptureScale.native`; a take at `.points` passes one that says 1, like the track's
/// `pixelScale`.
public final class DisplayGeometryRecorder: InputRecorder, Sendable {
    private struct State {
        var log: EventLogWriter?
        var generation = 0
        var paused = false
        var last: [UInt32: (frame: Rect, scale: Double)] = [:]
        var registration: Registration?
    }

    /// What `CGDisplayRegisterReconfigurationCallback` was given; registered and removed on the main actor, where
    /// the callback runs, so it is never removed while running. `@unchecked Sendable`: only handed to the main actor.
    private struct Registration: @unchecked Sendable {
        let box: Unmanaged<CallbackBox>
    }

    /// What the callback gets: a weak reference, so a recorder that was never stopped does not live on.
    fileprivate final class CallbackBox: @unchecked Sendable {
        weak var recorder: DisplayGeometryRecorder?

        init(_ recorder: DisplayGeometryRecorder) {
            self.recorder = recorder
        }
    }

    private let displayIDs: [UInt32]
    private let clock: @Sendable () -> HostTime
    private let query: @Sendable (UInt32) -> (frame: Rect, scale: Double)?
    private let state = Mutex(State())

    public init(
        displayIDs: [UInt32],
        clock: @escaping @Sendable () -> HostTime = HostTime.now,
        query: @escaping @Sendable (UInt32) -> (frame: Rect, scale: Double)? = DisplayGeometryRecorder.liveQuery
    ) {
        self.displayIDs = displayIDs
        self.clock = clock
        self.query = query
    }

    /// `CGDisplayBounds` and the pixels per point of the display's current mode, or `nil` if it is not online.
    public static func liveQuery(_ displayID: UInt32) -> (frame: Rect, scale: Double)? {
        guard let scale = DisplayCaptureSource.pixelScale(of: displayID) else { return nil }
        return (Rect(CGDisplayBounds(displayID)), scale)
    }

    public func start(log: EventLogWriter) async {
        let generation: Int? = state.withLock { s in
            guard s.log == nil else { return nil }
            s.log = log
            s.generation += 1
            s.paused = false
            s.last = [:]
            for displayID in displayIDs {
                if let geometry = query(displayID) { s.last[displayID] = geometry }
            }
            return s.generation
        }
        guard let generation else { return }

        let registration = Registration(box: Unmanaged.passRetained(CallbackBox(self)))
        await MainActor.run {
            _ = CGDisplayRegisterReconfigurationCallback(displayReconfigured, registration.box.toOpaque())
        }
        // stop() may have run meanwhile; then the callback must not stay.
        let keep = state.withLock { s in
            guard s.log != nil, s.generation == generation else { return false }
            s.registration = registration
            return true
        }
        if !keep { await Self.remove(registration) }
    }

    public func pause() async {
        state.withLock { s in
            guard s.log != nil else { return }
            s.paused = true
        }
    }

    public func resume() async {
        let resumed = state.withLock { s -> Bool in
            guard s.log != nil, s.paused else { return false }
            s.paused = false
            return true
        }
        if resumed { reconfigured() }
    }

    public func stop() async {
        let registration = state.withLock { s -> Registration? in
            defer {
                s.log = nil
                s.paused = false
                s.last = [:]
                s.registration = nil
            }
            return s.registration
        }
        if let registration { await Self.remove(registration) }
    }

    /// A reconfiguration ended: writes the displays whose frame or scale changed. Holding the lock across the append
    /// guarantees nothing is appended once `stop()` or `pause()` has returned.
    func reconfigured() {
        let time = clock()
        let current = displayIDs.map { ($0, query($0)) }
        state.withLock { s in
            guard let log = s.log, !s.paused else { return }
            for (displayID, geometry) in current {
                guard let geometry else { continue }
                if let last = s.last[displayID], last.frame == geometry.frame, last.scale == geometry.scale { continue }
                s.last[displayID] = geometry
                log.append(InputEvent(t: time, kind: .displayGeometry(displayID: displayID, frame: geometry.frame, scale: geometry.scale)))
            }
        }
    }

    private static func remove(_ registration: Registration) async {
        await MainActor.run {
            _ = CGDisplayRemoveReconfigurationCallback(displayReconfigured, registration.box.toOpaque())
            registration.box.release()
        }
    }
}

/// The reconfiguration callback: once per display at the beginning of a reconfiguration (ignored) and once per
/// display at its end.
private func displayReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?) {
    guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
    Unmanaged<DisplayGeometryRecorder.CallbackBox>.fromOpaque(userInfo).takeUnretainedValue().recorder?.reconfigured()
}
