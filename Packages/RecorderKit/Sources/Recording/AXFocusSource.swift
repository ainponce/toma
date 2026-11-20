// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ApplicationServices
import Foundation
import ProjectFormat
import Synchronization

/// The keyboard's focus in the app in front, read with Accessibility on a thread of its own (`dev.toma.focus`) with its
/// run loop. It needs Accessibility and never asks for it: without it granted (`AXIsProcessTrusted()`, which shows no
/// prompt) nothing is tried and `start` returns `false`.
///
/// It follows the app in front (`NSWorkspace.frontmostApplication` at the start, then
/// `didActivateApplicationNotification`, handed to its thread) with an `AXObserver` on the app's element for
/// `kAXFocusedUIElementChangedNotification` and `kAXSelectedTextChangedNotification`, and on the focused element, which
/// moves with each change of focus, for `kAXValueChangedNotification`. Toma's own process is never observed: with Toma
/// in front nothing is read. Each change asks for a reading on the schedule of `FocusReadSchedule`: at once, or when 50
/// ms have gone by since the last one, in one reading for all the changes until then.
///
/// A reading asks for the focused element's frame (`AXPosition` and `AXSize`), its role and subrole only to tell a secure
/// field (`isSecure(role:subrole:)`), and, unless it is one, the text cursor's rectangle: the bounds of the selection's
/// start (`AXSelectedTextRange`, `AXBoundsForRangeParameterizedAttribute`) with a length of 0 or else of one character
/// (`caretRanges(selection:characterCount:)`), narrowed to the cursor's edge (`caret(in:of:at:)`). Its time is when it
/// started. An app that does not tell where its text cursor is (Chrome or Electron without `AXManualAccessibility`) gives
/// only the element. Moving a window says nothing, so its rectangles stay as they were until the next reading.
///
/// Every query has a timeout of `messagingTimeout` (`AXUIElementSetMessagingTimeout` on the app's element and on each
/// focused element), so an app that does not answer holds only this thread, and never for long. No query runs on the
/// main thread. It only reads: no attribute of another app is ever set (neither `AXEnhancedUserInterface` nor
/// `AXManualAccessibility`). `stop()` stops the run loop and returns, never waiting for a query under way; that reading
/// may still reach the handler.
///
/// It hands on only rectangles and whether the field is secure: never what an element holds, its value, role, title or
/// app. It logs nothing.
public final class AXFocusSource: FocusSource {
    /// The longest any one Accessibility query waits for its app, in seconds: 50 ms.
    public static let messagingTimeout: Float = 0.05

    /// What a started source holds.
    private struct Running: @unchecked Sendable {
        let context: FocusContext
        let observer: any NSObjectProtocol
    }

    private let isTrusted: @Sendable () -> Bool
    private let clock: @Sendable () -> HostTime
    private let running = Mutex<Running?>(nil)

    public convenience init() {
        self.init(isTrusted: { AXIsProcessTrusted() }, clock: HostTime.now)
    }

    /// Tests say whether Accessibility is granted.
    init(isTrusted: @escaping @Sendable () -> Bool, clock: @escaping @Sendable () -> HostTime) {
        self.isTrusted = isTrusted
        self.clock = clock
    }

    deinit {
        stop()
    }

    public func start(handler: @escaping @Sendable (FocusReading, HostTime) -> Void) -> Bool {
        stop()
        guard isTrusted() else { return false }
        let context = FocusContext(handler: handler, clock: clock)
        let workspace = NSWorkspace.shared
        // Heard on the thread that posts it, and handed to the focus thread at once.
        let observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            context.frontChanged(to: app?.processIdentifier, heard: true)
        }
        context.frontChanged(to: workspace.frontmostApplication?.processIdentifier, heard: false)
        running.withLock { $0 = Running(context: context, observer: observer) }
        // The thread holds the context while its run loop can call the observer.
        let thread = Thread { context.run() }
        thread.name = "dev.toma.focus"
        thread.qualityOfService = .userInitiated
        thread.start()
        return true
    }

    public func stop() {
        guard let running = running.withLock({ $0.take() }) else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(running.observer)
        running.context.stop()
    }

    /// Whether the role or the subrole of an element says it is a secure field (`AXSecureTextField`).
    static func isSecure(role: String?, subrole: String?) -> Bool {
        role == secureTextField || subrole == secureTextField
    }

    private static let secureTextField = "AXSecureTextField"

    /// The ranges whose bounds are asked for, in order, for the text cursor of `selection` in a text of `characterCount`
    /// characters (`nil` if unknown): the selection's start with a length of 0, then its character (or, at the end of
    /// the text, the one before) with a length of 1.
    static func caretRanges(selection: CFRange, characterCount: Int?) -> [CFRange] {
        let location = max(0, selection.location)
        var ranges = [CFRange(location: location, length: 0)]
        if let count = characterCount, location >= count {
            if count > 0 { ranges.append(CFRange(location: count - 1, length: 1)) }
        } else {
            ranges.append(CFRange(location: location, length: 1))
        }
        return ranges
    }

    /// The text cursor at `location`, from the bounds `box` of `range`: the box itself for an empty range; for a
    /// character, its edge on the cursor's side (its leading edge if it is the character at the cursor, its trailing
    /// edge if it is the one before), with a width of 0.
    static func caret(in box: Rect, of range: CFRange, at location: Int) -> Rect {
        guard range.length > 0 else { return box }
        let x = range.location < location ? box.x + box.width : box.x
        return Rect(x: x, y: box.y, width: 0, height: box.height)
    }

    /// Whether the app of `pid` is observed: never Toma's own process.
    static func observes(_ pid: pid_t) -> Bool {
        pid > 0 && pid != ProcessInfo.processInfo.processIdentifier
    }
}

/// Called by the observer on the focus thread, with the context as its `refcon`.
private func focusDidChange(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    Unmanaged<FocusContext>.fromOpaque(refcon).takeUnretainedValue().changed()
}

/// What a started `AXFocusSource` runs on its thread. What `lock` guards is shared with the other threads; the rest is
/// only touched on the focus thread.
private final class FocusContext: @unchecked Sendable {
    /// The app observed, with its observer.
    private final class Observed {
        let pid: pid_t
        let app: AXUIElement
        let observer: AXObserver
        let source: CFRunLoopSource
        /// The focused element `kAXValueChangedNotification` is asked for on.
        var valueElement: AXUIElement?

        init(pid: pid_t, app: AXUIElement, observer: AXObserver, source: CFRunLoopSource) {
            self.pid = pid
            self.app = app
            self.observer = observer
            self.source = source
        }
    }

    /// A timer's fire date or interval that never comes.
    private static let never: CFTimeInterval = 1e9

    private let handler: @Sendable (FocusReading, HostTime) -> Void
    private let clock: @Sendable () -> HostTime

    private let lock = NSLock()
    /// Guarded by `lock`: the focus thread's run loop once it runs, whether `stop()` came, the app in front last told
    /// and whether an activation was heard (the app the start read is older than any).
    private var runLoop: CFRunLoop?
    private var stopped = false
    private var front: pid_t?
    private var heardActivation = false

    /// On the focus thread only.
    private var observed: Observed?
    /// The app in front last handled, observed or not.
    private var handledFront: pid_t?
    private var schedule = FocusReadSchedule()
    private var timer: CFRunLoopTimer?

    init(handler: @escaping @Sendable (FocusReading, HostTime) -> Void, clock: @escaping @Sendable () -> HostTime) {
        self.handler = handler
        self.clock = clock
    }

    private var isStopped: Bool {
        lock.withLock { stopped }
    }

    /// Any thread: the app of `pid` is in front (`nil`: none), as an activation `heard` or as the start read it.
    func frontChanged(to pid: pid_t?, heard: Bool) {
        let current = lock.withLock { () -> CFRunLoop? in
            guard heard || !heardActivation else { return nil }
            if heard { heardActivation = true }
            front = pid
            return stopped ? nil : runLoop
        }
        // Before the run loop runs, the thread reads `front` itself.
        guard let current else { return }
        CFRunLoopPerformBlock(current, CFRunLoopMode.defaultMode.rawValue) { [self] in checkFront() }
        CFRunLoopWakeUp(current)
    }

    /// Any thread: stops the run loop, or keeps it from running, and returns.
    func stop() {
        let current = lock.withLock { () -> CFRunLoop? in
            stopped = true
            return runLoop
        }
        guard let current else { return }
        // A stop before the run loop runs is lost, a block is not.
        CFRunLoopPerformBlock(current, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(CFRunLoopGetCurrent()) }
        CFRunLoopWakeUp(current)
        CFRunLoopStop(current)
    }

    /// On the focus thread: observes the app in front and runs the run loop until `stop()`; returns at once if `stop()`
    /// came first.
    func run() {
        guard let current = CFRunLoopGetCurrent() else { return }
        let goesOn = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            runLoop = current
            return true
        }
        guard goesOn else { return }
        // The reading put off to the end of the 50 ms. It also keeps the run loop from running out of sources.
        guard let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + Self.never, Self.never, 0, 0, { [weak self] _ in self?.readNow() })
        else { return }
        CFRunLoopAddTimer(current, timer, .defaultMode)
        self.timer = timer
        checkFront()
        while !isStopped {
            _ = CFRunLoopRunInMode(.defaultMode, Self.never, false)
        }
        unobserve()
        CFRunLoopTimerInvalidate(timer)
        self.timer = nil
    }

    /// On the focus thread: observes the app in front if it is another one than the last handled.
    private func checkFront() {
        guard !isStopped else { return }
        let pid = lock.withLock { front }
        guard pid != handledFront else { return }
        handledFront = pid
        unobserve()
        guard let pid, AXFocusSource.observes(pid) else { return }
        observe(pid)
    }

    /// On the focus thread: an observer on the app of `pid`, and a reading of where its focus is.
    private func observe(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AXFocusSource.messagingTimeout)
        var created: AXObserver?
        guard AXObserverCreate(pid, focusDidChange, &created) == .success, let observer = created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedUIElementChangedNotification, kAXSelectedTextChangedNotification] {
            _ = AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        observed = Observed(pid: pid, app: app, observer: observer, source: source)
        changed()
    }

    /// On the focus thread: the observer hears nothing more. It asks the app nothing, so an app that does not answer
    /// does not hold the change to the next one.
    private func unobserve() {
        guard let observed else { return }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), observed.source, .defaultMode)
        self.observed = nil
    }

    /// On the focus thread: something changed. Reads at once, or puts the reading off to the end of the 50 ms.
    func changed() {
        guard !isStopped, let timer else { return }
        let now = clock()
        guard let at = schedule.changed(at: now) else { return }
        guard at > now else { return readNow() }
        CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + Double(at.nanoseconds - now.nanoseconds) / 1e9)
    }

    /// On the focus thread: reads the focus and hands it on, with the time the reading started.
    private func readNow() {
        guard !isStopped else { return }
        let time = clock()
        schedule.didRead(at: time)
        if let timer { CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + Self.never) }
        guard let observed else { return }
        let reading = read(observed)
        guard !isStopped else { return }
        handler(reading, time)
    }

    /// On the focus thread: where the focus of the observed app is.
    private func read(_ observed: Observed) -> FocusReading {
        guard let focused = Self.element(observed.app, kAXFocusedUIElementAttribute) else {
            watchValue(of: nil, in: observed)
            return FocusReading(element: nil, caret: nil, isSecure: false)
        }
        AXUIElementSetMessagingTimeout(focused, AXFocusSource.messagingTimeout)
        watchValue(of: focused, in: observed)
        let secure = AXFocusSource.isSecure(
            role: Self.string(focused, kAXRoleAttribute), subrole: Self.string(focused, kAXSubroleAttribute))
        // A secure field's cursor is not even asked for.
        return FocusReading(element: Self.frame(of: focused), caret: secure ? nil : Self.caret(of: focused), isSecure: secure)
    }

    /// On the focus thread: `kAXValueChangedNotification` on `focused` alone.
    private func watchValue(of focused: AXUIElement?, in observed: Observed) {
        if let old = observed.valueElement {
            if let focused, CFEqual(old, focused) { return }
            _ = AXObserverRemoveNotification(observed.observer, old, kAXValueChangedNotification as CFString)
        }
        observed.valueElement = focused
        guard let focused else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(observed.observer, focused, kAXValueChangedNotification as CFString, refcon)
    }

    // MARK: - Queries

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name), CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    /// The `AXValue` of `type` an attribute holds, read into a copy of `empty`.
    private static func value<T: BitwiseCopyable>(_ element: AXUIElement, _ name: String, _ type: AXValueType, _ empty: T) -> T? {
        guard let value = attribute(element, name) else { return nil }
        return unpack(value, type, empty)
    }

    private static func unpack<T: BitwiseCopyable>(_ value: CFTypeRef, _ type: AXValueType, _ empty: T) -> T? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = empty
        guard AXValueGetValue(value as! AXValue, type, &result) else { return nil }
        return result
    }

    private static func frame(of element: AXUIElement) -> Rect? {
        guard let position = value(element, kAXPositionAttribute, .cgPoint, CGPoint.zero),
              let size = value(element, kAXSizeAttribute, .cgSize, CGSize.zero)
        else { return nil }
        return Rect(x: Double(position.x), y: Double(position.y), width: Double(size.width), height: Double(size.height))
    }

    /// The text cursor's rectangle in `element`, from the first range of `AXFocusSource.caretRanges` whose bounds give a
    /// valid one; `nil` for an element with no selection, or no bounds for it.
    private static func caret(of element: AXUIElement) -> Rect? {
        guard let selection = value(element, kAXSelectedTextRangeAttribute, .cfRange, CFRange(location: 0, length: 0))
        else { return nil }
        let count = attribute(element, kAXNumberOfCharactersAttribute).flatMap { ($0 as? NSNumber)?.intValue }
        let location = max(0, selection.location)
        for range in AXFocusSource.caretRanges(selection: selection, characterCount: count) {
            var asked = range
            guard let parameter = AXValueCreate(.cfRange, &asked) else { continue }
            var bounds: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &bounds) == .success,
                let bounds, let box = unpack(bounds, .cgRect, CGRect.zero)
            else { continue }
            let caret = AXFocusSource.caret(
                in: Rect(x: Double(box.origin.x), y: Double(box.origin.y), width: Double(box.width), height: Double(box.height)),
                of: range, at: location)
            if AccessibilityFocusRecorder.isValid(caret, as: .caret) { return caret }
        }
        return nil
    }
}
