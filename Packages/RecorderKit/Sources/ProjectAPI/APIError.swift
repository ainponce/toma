// SPDX-License-Identifier: GPL-3.0-or-later

/// The stable codes of what the project API refuses (fases 4 y 5 design §6.2): the `toma` command, the MCP server and the
/// control socket give them as they are, and `docs/format/README.md` lists them. A code is never renamed nor removed.
public enum APIErrorCode: String, Codable, Sendable, CaseIterable {
    /// The path is not a Toma package: not a folder `.toma` with a `manifest.json`, a link, a path with `..`, or a
    /// manifest that cannot be read.
    case notAProject
    /// The package or its edit document is of a newer version than this one reads.
    case newerVersion
    /// Another process (the app) is editing the project: it holds `edit.lock`.
    case locked
    /// The command is not one of the API's, or has a key it does not know, or lacks one it needs.
    case invalidCommand
    /// A time, a speed, a depth or a point is outside what the command takes.
    case outOfRange
    /// The command cannot be done to this project as it is (the reason is in the message), or its change could not be
    /// saved.
    case refused
    /// The export did not finish.
    case exportFailed
    /// What the command needs is not on this Mac (the transcription's engine or model) or not where it was asked.
    case notAvailable
}

/// What the project API throws: a stable `code` and a message in English for a person (or an agent) to read.
public struct APIError: Error, Equatable, Codable, Sendable, CustomStringConvertible {
    public let code: APIErrorCode
    public let message: String

    public init(_ code: APIErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code.rawValue): \(message)" }
}
