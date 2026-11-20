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
/// A reading (`reading(of:with:stopped:)`) asks for the focused element's role and subrole only to tell a secure field
/// (`isSecure(role:subrole:)`), its frame (`AXPosition` and `AXSize`), and, unless it is secure, the text cursor's
/// rectangle: the bounds of the selection's start (`AXSelectedTextRange`, `AXBoundsForRangeParameterizedAttribute`) with a
/// length of 0 or else of one character (`caretRanges(selection:characterCount:)`, asking for the text's length only
/// then), narrowed to the cursor's edge (`caret(in:of:at:)`). It fails closed: an element whose role or subrole cannot be
/// read (the app did not answer in time, or any other error) counts as secure, and its cursor is not even asked for. A
/// reading under way when `stop()` comes asks nothing more. Its time is when it started. An app that does not tell where its text cursor is (Chrome or Electron without `AXManualAccessibility`) gives
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

        /// Hears no more, and stops its thread without waiting for it.
        func stop() {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            context.stop()
        }
    }

    private let isTrusted: @Sendable () -> Bool
    private let clock: @Sendable () -> HostTime
    private let running = Mutex<Running?>(nil)
    private let threads = ThreadCount()

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

    /// The focus threads running now, the ones still ending included; for tests.
    var runningThreads: Int {
        threads.count
    }

    public func start(handler: @escaping @Sendable (FocusReading, HostTime) -> Void) -> Bool {
        guard isTrusted() else {
            stop()
            return false
        }
        let context = FocusContext(handler: handler, clock: clock, threads: threads)
        let workspace = NSWorkspace.shared
        // Heard on the thread that posts it, and handed to the focus thread at once.
        let observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            context.frontChanged(to: app?.processIdentifier, heard: true)
        }
        context.frontChanged(to: workspace.frontmostApplication?.processIdentifier, heard: false)
        // The one started before, by this start or by another at the same time, is swapped out and stopped: none is left.
        let previous = running.withLock { running -> Running? in
            defer { running = Running(context: context, observer: observer) }
            return running
        }
        previous?.stop()
        // The thread holds the context while its run loop can call the observer.
        let thread = Thread { context.run() }
        thread.name = "dev.toma.focus"
        thread.qualityOfService = .userInitiated
        thread.start()
        return true
    }

    public func stop() {
        running.withLock { $0.take() }?.stop()
    }

    /// Whether the role or the subrole of an element says it is a secure field (`AXSecureTextField`).
    static func isSecure(role: String?, subrole: String?) -> Bool {
        role == secureTextField || subrole == secureTextField
    }

    /// What a query of an element's role or subrole answered.
    enum AttributeAnswer: Equatable, Sendable {
        case value(String)
        /// The element has none (`.noValue`, `.attributeUnsupported`).
        case none
        /// It is not known: the app did not answer in time (`.cannotComplete`), any other error, or not a string.
        case unknown

        init(error: AXError, value: CFTypeRef?) {
            switch error {
            case .success:
                guard let value, CFGetTypeID(value) == CFStringGetTypeID() else {
                    self = .unknown
                    return
                }
                self = .value((value as! CFString) as String)
            case .noValue, .attributeUnsupported:
                self = .none
            default:
                self = .unknown
            }
        }

        var string: String? {
            if case let .value(string) = self { return string }
            return nil
        }
    }

    /// Whether an element whose role and subrole queries answered these is taken as secure: when either says
    /// `AXSecureTextField`, or either is not known. It fails closed, so a password field whose app was slow to answer
    /// never gives its text cursor.
    static func isSecure(role: AttributeAnswer, subrole: AttributeAnswer) -> Bool {
        role == .unknown || subrole == .unknown || isSecure(role: role.string, subrole: subrole.string)
    }

    /// The queries a reading asks of the focused element: Accessibility in the app, the test's own in the tests.
    protocol FocusQueries {
        associatedtype Element
        func role(of element: Element) -> AttributeAnswer
        func subrole(of element: Element) -> AttributeAnswer
        func frame(of element: Element) -> Rect?
        func selection(of element: Element) -> CFRange?
        func characterCount(of element: Element) -> Int?
        func bounds(of element: Element, for range: CFRange) -> Rect?
    }

    /// Where the focus is, with `element` the focused element: its role and subrole, its frame and, unless it is secure
    /// (`isSecure(role:subrole:)`, which fails closed), its text cursor (`caret(of:with:stopped:)`). `nil` once `stopped`
    /// says so between two queries: then nothing more is asked.
    static func reading<Queries: FocusQueries>(
        of element: Queries.Element, with queries: Queries, stopped: () -> Bool
    ) -> FocusReading? {
        let secure = isSecure(role: queries.role(of: element), subrole: queries.subrole(of: element))
        guard !stopped() else { return nil }
        let frame = queries.frame(of: element)
        guard !stopped() else { return nil }
        // A secure field's cursor, or that of one whose role is not known, is not even asked for.
        guard !secure else { return FocusReading(element: frame, caret: nil, isSecure: true) }
        guard let caret = caret(of: element, with: queries, stopped: stopped) else {
            return stopped() ? nil : FocusReading(element: frame, caret: nil, isSecure: false)
        }
        return FocusReading(element: frame, caret: caret, isSecure: false)
    }

    /// The text cursor's rectangle in `element`: the bounds of the empty range at the selection's start or, if they are
    /// not a valid cursor, those of the other range of `caretRanges` (the text's length is asked for only then),
    /// narrowed by `caret(in:of:at:)`. `nil` for an element with no selection or no valid bounds, and once `stopped`.
    static func caret<Queries: FocusQueries>(
        of element: Queries.Element, with queries: Queries, stopped: () -> Bool
    ) -> Rect? {
        guard let selection = queries.selection(of: element) else { return nil }
        let location = max(0, selection.location)
        func caret(for range: CFRange) -> Rect? {
            guard !stopped(), let box = queries.bounds(of: element, for: range) else { return nil }
            let caret = Self.caret(in: box, of: range, at: location)
            return AccessibilityFocusRecorder.isValid(caret, as: .caret) ? caret : nil
        }
        if let found = caret(for: CFRange(location: location, length: 0)) { return found }
        guard !stopped() else { return nil }
        let count = queries.characterCount(of: element)
        for range in caretRanges(selection: selection, characterCount: count).dropFirst() {
            if let found = caret(for: range) { return found }
        }
        return nil
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
    private let threads: ThreadCount

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

    init(
        handler: @escaping @Sendable (FocusReading, HostTime) -> Void, clock: @escaping @Sendable () -> HostTime,
        threads: ThreadCount
    ) {
        self.handler = handler
        self.clock = clock
        self.threads = threads
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
        threads.add(1)
        defer { threads.add(-1) }
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
        guard let observed, let reading = read(observed), !isStopped else { return }
        handler(reading, time)
    }

    /// On the focus thread: where the focus of the observed app is; `nil` once `stop()` came.
    private func read(_ observed: Observed) -> FocusReading? {
        guard let focused = AXElementQueries.element(observed.app, kAXFocusedUIElementAttribute) else {
            watchValue(of: nil, in: observed)
            return FocusReading(element: nil, caret: nil, isSecure: false)
        }
        AXUIElementSetMessagingTimeout(focused, AXFocusSource.messagingTimeout)
        guard !isStopped else { return nil }
        watchValue(of: focused, in: observed)
        return AXFocusSource.reading(of: focused, with: AXElementQueries(), stopped: { isStopped })
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
}

/// How many focus threads run, across the starts of one source.
private final class ThreadCount: Sendable {
    private let value = Mutex(0)

    var count: Int { value.withLock { $0 } }

    func add(_ delta: Int) {
        value.withLock { $0 += delta }
    }
}

/// The queries of a reading, with Accessibility: each one waits for the app at most the element's messaging timeout.
private struct AXElementQueries: AXFocusSource.FocusQueries {
    func role(of element: AXUIElement) -> AXFocusSource.AttributeAnswer {
        Self.answer(element, kAXRoleAttribute)
    }

    func subrole(of element: AXUIElement) -> AXFocusSource.AttributeAnswer {
        Self.answer(element, kAXSubroleAttribute)
    }

    func frame(of element: AXUIElement) -> Rect? {
        guard let position = Self.value(element, kAXPositionAttribute, .cgPoint, CGPoint.zero),
              let size = Self.value(element, kAXSizeAttribute, .cgSize, CGSize.zero)
        else { return nil }
        return Rect(x: Double(position.x), y: Double(position.y), width: Double(size.width), height: Double(size.height))
    }

    func selection(of element: AXUIElement) -> CFRange? {
        Self.value(element, kAXSelectedTextRangeAttribute, .cfRange, CFRange(location: 0, length: 0))
    }

    func characterCount(of element: AXUIElement) -> Int? {
        Self.attribute(element, kAXNumberOfCharactersAttribute).flatMap { ($0 as? NSNumber)?.intValue }
    }

    func bounds(of element: AXUIElement, for range: CFRange) -> Rect? {
        var asked = range
        guard let parameter = AXValueCreate(.cfRange, &asked) else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &bounds) == .success,
            let bounds, let box = Self.unpack(bounds, .cgRect, CGRect.zero)
        else { return nil }
        return Rect(x: Double(box.origin.x), y: Double(box.origin.y), width: Double(box.width), height: Double(box.height))
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// A string attribute, telling "it has none" from "not known".
    static func answer(_ element: AXUIElement, _ name: String) -> AXFocusSource.AttributeAnswer {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return AXFocusSource.AttributeAnswer(error: error, value: value)
    }

    /// The `AXValue` of `type` an attribute holds, read into a copy of `empty`.
    static func value<T: BitwiseCopyable>(_ element: AXUIElement, _ name: String, _ type: AXValueType, _ empty: T) -> T? {
        guard let value = attribute(element, name) else { return nil }
        return unpack(value, type, empty)
    }

    static func unpack<T: BitwiseCopyable>(_ value: CFTypeRef, _ type: AXValueType, _ empty: T) -> T? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = empty
        guard AXValueGetValue(value as! AXValue, type, &result) else { return nil }
        return result
    }
}
