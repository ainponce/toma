// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Testing

/// The build settings of `Config/Identity.xcconfig`, by name; `//` starts a comment.
private func identitySettings() throws -> [String: String] {
    let root = URL(fileURLWithPath: #filePath)  // <root>/Packages/RecorderKit/Tests/AppSupportTests/IdentityTests.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let text = try String(contentsOf: root.appendingPathComponent("Config/Identity.xcconfig"), encoding: .utf8)
    var settings: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let content = line.components(separatedBy: "//")[0]
        let parts = content.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        settings[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
    }
    return settings
}

@Test func theAppDeclaresTheProjectExtensionTheFormatUses() throws {
    let settings = try identitySettings()
    #expect(settings["PROJECT_FILE_EXTENSION"] == ProjectPackage.fileExtension)
    #expect(settings["PROJECT_TYPE_IDENTIFIER"]?.isEmpty == false)
}
