// SPDX-License-Identifier: GPL-3.0-or-later
import CoreAudio
import Darwin
import Foundation

/// A process connected to the audio system: one Core Audio process object.
public struct AudioProcessInfo: Equatable, Sendable {
    /// Its Core Audio process object, what a tap names.
    public var objectID: AudioObjectID
    public var pid: pid_t
    /// `nil` for a process without one (a daemon, a command-line tool).
    public var bundleIdentifier: String?
    /// `nil` once the process has exited.
    public var executablePath: String?
    /// Whether it is playing audio now (`kAudioProcessPropertyIsRunningOutput`).
    public var isPlayingAudio: Bool

    public init(objectID: AudioObjectID, pid: pid_t, bundleIdentifier: String?, executablePath: String?, isPlayingAudio: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
        self.isPlayingAudio = isPlayingAudio
    }
}

/// The processes connected to the audio system, read from Core Audio. Reading them needs no permission.
public enum AudioProcessCatalog {
    /// Every process connected to the audio system now. A process that exits while it is being read is left out.
    /// Throws `CaptureSourceError.systemAudioUnavailable` if the list cannot be read.
    public static func processes() throws -> [AudioProcessInfo] {
        var address = globalAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        var status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard status == noErr else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        var objects = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = objects.withUnsafeMutableBytes { bytes in
            size = UInt32(bytes.count)
            return AudioObjectGetPropertyData(system, &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        return objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap(process)
    }

    /// The process object of `pid`, or `nil` if that process is not connected to the audio system.
    public static func objectID(forPID pid: pid_t) throws -> AudioObjectID? {
        var address = globalAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &objectID)
        guard status == noErr else { throw CaptureSourceError.systemAudioUnavailable(status: status) }
        return objectID == kAudioObjectUnknown ? nil : objectID
    }

    private static func process(_ objectID: AudioObjectID) -> AudioProcessInfo? {
        var pid: pid_t = -1
        guard read(kAudioProcessPropertyPID, of: objectID, into: &pid), pid > 0 else { return nil }
        var running: UInt32 = 0
        guard read(kAudioProcessPropertyIsRunningOutput, of: objectID, into: &running) else { return nil }
        return AudioProcessInfo(
            objectID: objectID, pid: pid, bundleIdentifier: bundleIdentifier(of: objectID), executablePath: executablePath(of: pid),
            isPlayingAudio: running != 0)
    }

    /// The process's bundle ID; `nil` when it has none (Core Audio gives an empty string) or it cannot be read.
    private static func bundleIdentifier(of objectID: AudioObjectID) -> String? {
        var address = globalAddress(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0) }
        // The caller releases the string Core Audio returns.
        guard status == noErr, let bundle = value?.takeRetainedValue() as String?, !bundle.isEmpty else { return nil }
        return bundle
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func read<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, of objectID: AudioObjectID, into value: inout T) -> Bool {
        var address = globalAddress(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}
