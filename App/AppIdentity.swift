// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The app's name and version, from its Info.plist.
enum AppIdentity {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
