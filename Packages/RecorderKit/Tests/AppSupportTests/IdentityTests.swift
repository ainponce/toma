// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Testing

/// The lines of `Config/Identity.xcconfig` that set something, as (name, value as written).
private func identityLines() throws -> [(name: String, value: String)] {
    let root = URL(fileURLWithPath: #filePath)  // <root>/Packages/RecorderKit/Tests/AppSupportTests/IdentityTests.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let text = try String(contentsOf: root.appendingPathComponent("Config/Identity.xcconfig"), encoding: .utf8)
    return text.split(separator: "\n").compactMap { line in
        guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { return nil }
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return (parts[0].trimmingCharacters(in: .whitespaces), String(parts[1]))
    }
}

/// The build settings of `Config/Identity.xcconfig`, by name; `//` starts a comment.
private func identitySettings() throws -> [String: String] {
    var settings: [String: String] = [:]
    for (name, value) in try identityLines() {
        settings[name] = value.components(separatedBy: "//")[0].trimmingCharacters(in: .whitespaces)
    }
    return settings
}

@Test func theAppDeclaresTheProjectExtensionTheFormatUses() throws {
    let settings = try identitySettings()
    #expect(settings["PROJECT_FILE_EXTENSION"] == ProjectPackage.fileExtension)
    #expect(settings["PROJECT_TYPE_IDENTIFIER"]?.isEmpty == false)
}

/// A setting's value as Xcode expands it: `$()` is empty, which is how `//` is written in a .xcconfig.
private func expanded(_ value: String) -> String {
    value.replacingOccurrences(of: "$()", with: "")
}

/// A URL or a base64 key written with `//` would be cut there, without any error from Xcode.
@Test(arguments: ["SPARKLE_FEED_URL", "SPARKLE_PUBLIC_KEY"])
func updateSettingsHaveNoCommentCuttingThemShort(name: String) throws {
    let line = try #require(try identityLines().first { $0.name == name }, "\(name) is declared")
    #expect(!line.value.contains("//"), "\(name) = \(line.value): write each // as /$()/")
}

@Test func theUpdateFeedIsTheURLOfAnAppcast() throws {
    let feed = try #require(try identitySettings()["SPARKLE_FEED_URL"].map(expanded))
    let url = try #require(URL(string: feed), "\(feed)")
    #expect(url.scheme == "http" || url.scheme == "https", "\(feed)")
    #expect(url.host()?.isEmpty == false, "\(feed)")
    #expect(url.lastPathComponent == "appcast.xml", "\(feed)")
}

@Test func theUpdatePublicKeyIsUnsetOrAnEdDSAKey() throws {
    let key = try #require(try identitySettings()["SPARKLE_PUBLIC_KEY"].map(expanded), "SPARKLE_PUBLIC_KEY is declared")
    // Not created yet: the app starts without its updater.
    guard !key.isEmpty else { return }
    #expect(Data(base64Encoded: key)?.count == 32, "\(key): a 32-byte Ed25519 key in base64")
}
