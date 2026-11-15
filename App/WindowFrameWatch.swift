// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import ProjectFormat

/// The frame of the window Window mode records, read again from the window server (`kCGWindowBounds`) every
/// `interval` while it is watched: the camera bubble's region, so the bubble follows the window when it moves
/// (notch design §5.6).
@MainActor
final class WindowFrameWatch {
    static let interval = Duration.milliseconds(250)

    /// The window's frame as it was last read; `nil` once it is closed, or while nothing is watched.
    private(set) var frame: Rect?
    /// The frame read changed.
    var moved: () -> Void = {}

    private var windowID: UInt32?
    private var task: Task<Void, Never>?

    /// Reads `windowID`'s frame now and goes on reading it; `nil` stops. Watching the window already watched
    /// changes nothing.
    func watch(_ windowID: UInt32?) {
        guard let windowID else {
            stop()
            return
        }
        guard windowID != self.windowID || task == nil else { return }
        task?.cancel()
        self.windowID = windowID
        frame = WindowList.window(windowID)?.frame
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled, let self else { return }
                read()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        windowID = nil
        frame = nil
    }

    private func read() {
        guard let windowID else { return }
        let now = WindowList.window(windowID)?.frame
        guard now != frame else { return }
        frame = now
        moved()
    }
}
