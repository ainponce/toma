// SPDX-License-Identifier: GPL-3.0-or-later
import ColorSync
import CoreGraphics
import Darwin
import Foundation

/// Every display's desktops, read from CoreGraphics Services: the project's one use of a private API, the
/// exception the owner approved (notch design §3). Only this type loads it, at run time with `dlsym`, and
/// only two functions that read: `CGSMainConnectionID` and `CGSCopyManagedDisplaySpaces`. Nothing here
/// writes or changes the desktop. Without either function, or with a result of another shape, there is no
/// list (`nil`) and the island shows ← → and Mission Control instead; no recording depends on it.
public final class SpacesReader: Sendable {
    /// The functions looked up once, for the life of the app.
    public static let live = SpacesReader(copySpaces: lookUpCopySpaces())

    /// What `CGSCopyManagedDisplaySpaces` returns for this app's connection; `nil` without the functions.
    let copySpaces: (@Sendable () -> Any?)?

    init(copySpaces: (@Sendable () -> Any?)?) {
        self.copySpaces = copySpaces
    }

    /// The desktops of every display now, or `nil` if they cannot be read. Never throws or stops the app:
    /// whatever comes back goes through `DesktopSpaces.parse`.
    public func snapshot() -> [DisplaySpaces]? {
        guard let copySpaces, let raw = copySpaces() else { return nil }
        return DesktopSpaces.parse(raw)
    }

    /// The UUID that names the display in `snapshot()` (`DisplaySpaces.displayIdentifier`), from public API.
    public static func displayUUID(for displayID: UInt32) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    /// The two functions from the images already loaded (`RTLD_DEFAULT`), or `nil` if either is missing.
    private static func lookUpCopySpaces() -> (@Sendable () -> Any?)? {
        let everyImage = UnsafeMutableRawPointer(bitPattern: -2)
        guard let mainConnection = dlsym(everyImage, "CGSMainConnectionID"),
            let copyManagedDisplaySpaces = dlsym(everyImage, "CGSCopyManagedDisplaySpaces")
        else { return nil }
        let connection = unsafeBitCast(mainConnection, to: MainConnectionID.self)
        let copy = unsafeBitCast(copyManagedDisplaySpaces, to: CopyManagedDisplaySpaces.self)
        return { copy(connection())?.takeRetainedValue() }
    }
}
