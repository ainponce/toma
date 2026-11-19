// SPDX-License-Identifier: GPL-3.0-or-later
import Carbon
import CoreGraphics
import Dispatch
import Foundation
import os
import ProjectFormat
import Synchronization

/// A key that went down, as `KeyPressRecorder` writes it (`InputEvent.Kind.keyPress`).
public struct KeyEvent: Equatable, Sendable {
    /// The virtual key code (`kCGKeyboardEventKeycode`).
    public var code: UInt16
    /// What the key types with only ⇧ of its modifiers, in the keyboard layout in use (a dead key gives its own
    /// character); `nil` for a key that types nothing or a control character (↩, ⇥, ⌫, ⌦, esc, the arrows, the function
    /// keys).
    public var chars: String?
    /// The event's flags (`CGEventFlags`, their low 32 bits), as they came: the recorder keeps only
    /// `KeyPressRecorder.modifierMask`.
    public var mods: UInt32
    /// The key's automatic repeat (`keyboardEventAutorepeat`).
    public var isRepeat: Bool
    /// What the key types with no modifier at all, in the same layout (`"4"` where ⇧4 makes `chars` `"$"`): the key's
    /// own label for a shortcut, whatever the keyboard. `nil` where `chars` is.
    public var key: String?

    public init(code: UInt16, chars: String?, mods: UInt32, isRepeat: Bool, key: String? = nil) {
        self.code = code
        self.chars = chars
        self.mods = mods
        self.isRepeat = isRepeat
        self.key = key
    }
}

/// Where `KeyPressRecorder` hears the keys.
public protocol KeyEventSource: AnyObject, Sendable {
    /// Calls `handler` on `queue` for each key that goes down from now on, with the host time it went down, until
    /// `stop()`. Returns `false`, and calls nothing, if the keyboard cannot be listened to.
    func start(on queue: DispatchSerialQueue, handler: @escaping @Sendable (KeyEvent, HostTime) -> Void) -> Bool
    /// Listens no more. A key already handed to the queue may still reach the handler. Does nothing unless started.
    func stop()
}

/// The keys of every app, from a listen-only `CGEventTap` of `keyDown` on a thread of its own with its run loop: it sees
/// the keys and changes nothing. It needs Input Monitoring and never asks for it: without it granted
/// (`CGPreflightListenEventAccess`) the tap is not even tried, since making one would show the prompt, and `start`
/// returns `false`. The tap is enabled again when macOS disables it (`tapDisabledByTimeout`, `tapDisabledByUserInput`).
///
/// Each key's time is `HostTime.now()` when the tap is called (the event's own timestamp is not used: its unit depends
/// on the Mac). Nothing is handed on while secure input is on (`IsSecureEventInputEnabled()`, read as the key comes;
/// `KeyPressRecorder` reads it again). `chars` comes from `UCKeyTranslate` with only ⇧ and `key` with no modifier, both
/// with `kUCKeyTranslateNoDeadKeysMask`, on the keyboard layout read on the main thread (Text Input Sources) when the tap
/// starts and each time the user picks another input source. Until a start's reading comes, the keys use the reading
/// before it (a resume keeps `chars`); a key in the moment before the very first reading has no `chars`.
public final class KeyEventTap: KeyEventSource {
    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "KeyEventTap")

    /// What a started tap holds. Its CoreFoundation objects are only used through calls that are safe from any thread.
    private struct Running: @unchecked Sendable {
        let context: TapContext
        let port: CFMachPort
        let source: CFRunLoopSource
        let thread: TapThread
        let observer: (any NSObjectProtocol)?
    }

    private let running = Mutex<Running?>(nil)
    /// Kept across starts: a start (a resume) reads the layout again, and until then the keys keep the last reading.
    private let layout = KeyboardLayout()

    public init() {}

    deinit {
        stop()
    }

    /// Starting a tap that is started already starts it again, with the new handler.
    public func start(on queue: DispatchSerialQueue, handler: @escaping @Sendable (KeyEvent, HostTime) -> Void) -> Bool {
        stop()
        guard CGPreflightListenEventAccess() else {
            Self.logger.notice("The keys are not recorded: Input Monitoring is not granted (no prompt is shown).")
            return false
        }
        let context = TapContext(queue: queue, handler: handler, layout: layout)
        let mask = CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return nil }
                let context = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()
                // The type first: for the tap being disabled the event may be NULL, so it is not touched. A listen-only
                // tap's answer changes nothing, so nil is as good as the event.
                switch type {
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    context.enableAgain()
                    return nil
                case .keyDown:
                    context.keyDown(event)
                    return Unmanaged.passUnretained(event)
                default:
                    return nil
                }
            },
            userInfo: Unmanaged.passUnretained(context).toOpaque())
        else {
            Self.logger.notice("The keys are not recorded: the keyboard's event tap could not be made.")
            return false
        }
        context.port = port
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            Self.logger.notice("The keys are not recorded: the keyboard's event tap has no run loop source.")
            return false
        }
        let layout = layout
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { layout.refresh() }
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { layout.refresh() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { layout.refresh() } }
        }
        let tap = Running(context: context, port: port, source: source, thread: TapThread(), observer: observer)
        running.withLock { $0 = tap }
        // The thread holds the context while its run loop can call the tap.
        let thread = Thread { tap.thread.run(tap.source, keeping: tap.context) }
        thread.name = "dev.toma.key-event-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    public func stop() {
        guard let tap = running.withLock({ $0.take() }) else { return }
        tap.context.stop()
        CGEvent.tapEnable(tap: tap.port, enable: false)
        CFRunLoopSourceInvalidate(tap.source)
        CFMachPortInvalidate(tap.port)
        tap.thread.stop()
        if let observer = tap.observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }
}

extension KeyEventTap {
    /// The key `code` that went down with `flags`, read in `layout`: `chars` with only ⇧ of `flags`, `key` with none.
    static func keyEvent(
        code: UInt16, flags: CGEventFlags, keyboardType: UInt32, isRepeat: Bool, layout: KeyboardLayout
    ) -> KeyEvent {
        let shift = flags.contains(.maskShift)
        let chars = layout.characters(code: code, shift: shift, keyboardType: keyboardType)
        // With no ⇧, what it types with only ⇧ is what it types with none; a key that types nothing has no `key` either.
        let key = chars == nil || !shift ? chars : layout.characters(code: code, shift: false, keyboardType: keyboardType)
        return KeyEvent(code: code, chars: chars, mods: UInt32(truncatingIfNeeded: flags.rawValue), isRepeat: isRepeat, key: key)
    }
}

/// What the tap's callback reaches through its `userInfo`.
private final class TapContext: @unchecked Sendable {
    let queue: DispatchSerialQueue
    let handler: @Sendable (KeyEvent, HostTime) -> Void
    /// The tap's, kept across its starts.
    let layout: KeyboardLayout
    /// Set once, before the tap's thread starts; read on that thread to enable the tap again.
    var port: CFMachPort?
    private let stopped = Atomic(false)

    init(queue: DispatchSerialQueue, handler: @escaping @Sendable (KeyEvent, HostTime) -> Void, layout: KeyboardLayout) {
        self.queue = queue
        self.handler = handler
        self.layout = layout
    }

    func stop() {
        stopped.store(true, ordering: .releasing)
    }

    /// On the tap's thread: macOS disabled the tap (`tapDisabledByTimeout`, `tapDisabledByUserInput`), with no event.
    func enableAgain() {
        guard !stopped.load(ordering: .acquiring), let port else { return }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// On the tap's thread: a key went down.
    func keyDown(_ event: CGEvent) {
        let time = HostTime.now()
        guard !stopped.load(ordering: .acquiring), !IsSecureEventInputEnabled() else { return }
        let key = KeyEventTap.keyEvent(
            code: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags,
            keyboardType: UInt32(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeyboardType)),
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, layout: layout)
        let handler = handler
        queue.async { handler(key, time) }
    }
}

/// The tap's thread: runs its run loop until `stop()`.
private final class TapThread: @unchecked Sendable {
    private let lock = NSLock()
    /// Guarded by `lock`.
    private var runLoop: CFRunLoop?
    private var stopped = false

    /// On the tap's thread: adds `source` to its run loop and runs it until `stop()`, holding `context`; returns at once
    /// if `stop()` came first. A source that `stop()` invalidates before the run loop runs leaves it empty, so it
    /// returns at once too.
    func run(_ source: CFRunLoopSource, keeping context: TapContext) {
        lock.lock()
        guard !stopped, let current = CFRunLoopGetCurrent() else {
            lock.unlock()
            return
        }
        CFRunLoopAddSource(current, source, .commonModes)
        runLoop = current
        lock.unlock()
        withExtendedLifetime(context) { CFRunLoopRun() }
    }

    func stop() {
        lock.lock()
        stopped = true
        let current = runLoop
        lock.unlock()
        if let current { CFRunLoopStop(current) }
    }
}

/// The `uchr` data of the keyboard layout in use, read on the main thread (Text Input Sources is main-thread API);
/// `UCKeyTranslate` reads it from any thread.
final class KeyboardLayout: Sendable {
    private struct Layout {
        var data: Data
        var keyboardType: UInt32
    }

    private let layout = Mutex<Layout?>(nil)

    /// Reads the layout in use again.
    @MainActor func refresh() {
        let current = Self.current()
        layout.withLock { $0 = current }
    }

    /// What `code` types with only ⇧ (if `shift`) in the layout read last, for a keyboard of `keyboardType`
    /// (`kCGKeyboardEventKeyboardType`; 0 for the one read with the layout). `nil` before the first reading.
    func characters(code: UInt16, shift: Bool, keyboardType: UInt32) -> String? {
        guard let current = layout.withLock({ $0 }) else { return nil }
        return Self.characters(
            in: current.data, code: code, shift: shift, keyboardType: keyboardType == 0 ? current.keyboardType : keyboardType)
    }

    /// What `code` types with only ⇧ (if `shift`), dead keys giving their own character, in the `uchr` layout `data`:
    /// `nil` for a key that types nothing or a control character.
    static func characters(in data: Data, code: UInt16, shift: Bool, keyboardType: UInt32) -> String? {
        data.withUnsafeBytes { bytes -> String? in
            guard let base = bytes.baseAddress, bytes.count >= MemoryLayout<UCKeyboardLayout>.size else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var units = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self), code, UInt16(kUCKeyActionDown),
                shift ? UInt32(shiftKey >> 8) & 0xFF : 0, keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeys, units.count, &length, &units)
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: units, count: length)
            guard !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
            return text
        }
    }

    @MainActor private static func current() -> Layout? {
        let copies = [TISCopyCurrentKeyboardLayoutInputSource, TISCopyCurrentASCIICapableKeyboardLayoutInputSource]
        for copy in copies {
            guard let source = copy()?.takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { continue }
            let cfData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
            // A copy: the source owns its data.
            let data = Data(bytes: CFDataGetBytePtr(cfData), count: CFDataGetLength(cfData))
            return Layout(data: data, keyboardType: UInt32(LMGetKbdType()))
        }
        return nil
    }
}
