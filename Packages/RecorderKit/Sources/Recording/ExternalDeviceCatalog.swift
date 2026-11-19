// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMediaIO
import Synchronization

/// An iPhone or iPad connected by cable whose screen can be recorded.
public struct ExternalDeviceInfo: Equatable, Sendable {
    /// `AVCaptureDevice.uniqueID`: the same each time that device is connected.
    public var uniqueID: String
    public var name: String
    /// `AVCaptureDevice.modelID`.
    public var modelID: String

    public init(uniqueID: String, name: String, modelID: String) {
        self.uniqueID = uniqueID
        self.name = name
        self.modelID = modelID
    }
}

/// The iPhones and iPads connected by cable, as QuickTime finds them: CoreMediaIO screen-capture devices, which
/// AVFoundation lists as `.external` devices of `.muxed` media once `allowScreenCaptureDevices()` has run. Listing
/// them needs no permission; recording one needs the camera's.
public enum ExternalDeviceCatalog {
    /// Lets this process see the screens of iPhones and iPads (`kCMIOHardwarePropertyAllowScreenCaptureDevices` = 1
    /// on the system object): set once per process, tried again only while it fails. The devices show up a moment
    /// later (`AVCaptureDevice.wasConnectedNotification`). `true` once it is set.
    ///
    /// CoreMediaIO may take a while, and this waits for it: never on the main thread (the capture calls it on its
    /// session's queue). The main actor uses the `async` one.
    @discardableResult
    public static func allowScreenCaptureDevices() -> Bool {
        screenCaptureDevices.apply()
    }

    /// The same, for callers on the main actor (the iPhone mode calls it as it opens): CoreMediaIO is called off it,
    /// at user-initiated QoS, and the caller waits without holding its thread.
    @discardableResult
    public static func allowScreenCaptureDevices() async -> Bool {
        await screenCaptureDevices.apply()
    }

    /// The iPhones and iPads connected now, in the system's order. Empty until `allowScreenCaptureDevices()`.
    public static func devices() -> [ExternalDeviceInfo] {
        discover().map(\.info)
    }

    /// Whether a device is the screen of an iPhone or iPad: an external device that carries muxed media (video and
    /// sound together). A USB camera is external but only video; an iPhone used as the Mac's camera is a Continuity
    /// Camera.
    static func isScreenDevice(type: AVCaptureDevice.DeviceType, hasMuxed: Bool) -> Bool {
        type == .external && hasMuxed
    }

    /// The device of `listed` whose `uniqueID` is `uniqueID`: only that one, never another device connected
    /// meanwhile. Throws `CaptureSourceError.deviceNotFound(uniqueID:)` if it is not there.
    static func pick<Device>(_ uniqueID: String, among listed: [(info: ExternalDeviceInfo, device: Device)])
        throws(CaptureSourceError) -> Device
    {
        guard let match = listed.first(where: { $0.info.uniqueID == uniqueID }) else {
            throw .deviceNotFound(uniqueID: uniqueID)
        }
        return match.device
    }

    /// The connected device `uniqueID` (`pick` over `discover()`).
    static func resolve(_ uniqueID: String) throws(CaptureSourceError) -> AVCaptureDevice {
        try pick(uniqueID, among: discover())
    }

    /// The screen devices connected now, with their devices.
    static func discover() -> [(info: ExternalDeviceInfo, device: AVCaptureDevice)] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
            .filter { isScreenDevice(type: $0.deviceType, hasMuxed: $0.hasMediaType(.muxed)) }
            .map { device in
                (info: ExternalDeviceInfo(uniqueID: device.uniqueID, name: device.localizedName, modelID: device.modelID),
                 device: device)
            }
    }

    private static let screenCaptureDevices = OneTimeSetting { setAllowsScreenCaptureDevices() }

    /// Sets `kCMIOHardwarePropertyAllowScreenCaptureDevices` to 1. `true` if CoreMediaIO took it.
    private static func setAllowsScreenCaptureDevices() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        let status = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
        return status == kCMIOHardwareNoError
    }
}

/// A setting of the whole process that is made once: `apply` makes it until it holds, then never again.
///
/// It is made on a serial queue of its own, at user-initiated QoS, with no lock held: calls at the same time wait in
/// line behind the one making it, and find it made (or try again if that one failed). Once it holds, a call returns
/// at once, without the queue.
final class OneTimeSetting: Sendable {
    private let holds = Atomic(false)
    private let queue = DispatchSerialQueue(label: "dev.toma.OneTimeSetting", qos: .userInitiated)
    private let make: @Sendable () -> Bool

    /// `make` sets it, and says whether it took.
    init(_ make: @escaping @Sendable () -> Bool) {
        self.make = make
    }

    /// Makes the setting unless it already holds, and waits for it there: never on the main thread. `true` once it
    /// holds.
    func apply() -> Bool {
        if holds.load(ordering: .acquiring) { return true }
        dispatchPrecondition(condition: .notOnQueue(.main))
        return queue.sync { applyOnQueue() }
    }

    /// The same, waiting without holding the caller's thread: for the main actor.
    func apply() async -> Bool {
        if holds.load(ordering: .acquiring) { return true }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.applyOnQueue()) }
        }
    }

    private func applyOnQueue() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        // A call that waited in line behind the one that made it.
        if holds.load(ordering: .acquiring) { return true }
        let made = make()
        if made { holds.store(true, ordering: .releasing) }
        return made
    }
}
