// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// What the hooks prepared for the takes they wrap (`TakeHooks.takeWillStart`).
public struct TakePreparation: Equatable, Sendable {
    /// Windows of this app the displays' recording keeps (`TakeRequest.includedWindowIDs`).
    public var includedWindowIDs: [UInt32]
    /// What the user should know about the take: what the hooks could not do.
    public var notices: [TakeNotice]

    public init(includedWindowIDs: [UInt32] = [], notices: [TakeNotice] = []) {
        self.includedWindowIDs = includedWindowIDs
        self.notices = notices
    }
}

/// What runs around the takes `RecordingController` records: from before the countdown until the last take is closed,
/// restarts included.
@MainActor
public protocol TakeHooks: AnyObject {
    /// Before the countdown (with it on screen), once the permissions are answered; never again for a restart. Whatever
    /// happens next, `takeDidEnd` comes once.
    func takeWillStart(_ request: TakeRequest) async -> TakePreparation
    /// A take of `package` records now as `takeID`, for `request`: once for each take, a restart's too.
    func takeDidStart(package: ProjectPackage, takeID: String, request: TakeRequest) async
    /// The takes are over: the last one was closed, or the start was stopped or failed.
    func takeDidEnd() async
}

/// Do Not Disturb around the takes, with the shortcut `shortcut` says is chosen (read at every start).
@MainActor
public final class FocusTakeHooks: TakeHooks {
    private let focus: FocusGuard
    private let shortcut: @MainActor () -> String?

    public init(focus: FocusGuard, shortcut: @escaping @MainActor () -> String?) {
        self.focus = focus
        self.shortcut = shortcut
    }

    /// A shortcut that did not run says so (`focusShortcutFailed`); the take starts anyway.
    public func takeWillStart(_ request: TakeRequest) async -> TakePreparation {
        await focus.takeWillStart(shortcut: shortcut()) ? TakePreparation() : TakePreparation(notices: [.focusShortcutFailed])
    }

    public func takeDidStart(package: ProjectPackage, takeID: String, request: TakeRequest) async {}

    public func takeDidEnd() async {
        await focus.takeDidEnd()
    }
}
