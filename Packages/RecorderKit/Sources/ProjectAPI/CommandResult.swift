// SPDX-License-Identifier: GPL-3.0-or-later

/// What a command, an undo or a redo did.
public struct CommandResult: Codable, Equatable, Sendable {
    /// Who applied it: the API on the package (`project`), or the app that has it open, through its control socket.
    public enum Via: String, Codable, Sendable { case project, app }

    /// The command's name (`ProjectCommand.name`), or `undo` or `redo`.
    public var command: String
    /// Whether the document changed: a setter given the value the project has already changes nothing, and is no error.
    public var changed: Bool
    /// The undo label of the step (`EditLabel`'s raw value, as the edit log writes it): for an undo or a redo, the one
    /// it undid or redid. `nil` when nothing changed.
    public var label: String?
    /// The id of what the command made: a zoom block, a marker, a title card, a text or a piece of music.
    public var created: String?
    /// The length of the output afterwards, in seconds.
    public var duration: Double
    /// The label of what an undo would undo now; `nil` with nothing to undo.
    public var undo: String?
    public var via: Via

    public init(
        command: String, changed: Bool, label: String?, created: String?, duration: Double, undo: String?, via: Via
    ) {
        self.command = command
        self.changed = changed
        self.label = label
        self.created = created
        self.duration = duration
        self.undo = undo
        self.via = via
    }
}

/// What a list of commands did (plan 4b decision 6): they run in order and stop at the first that fails, whose error and
/// index are here; those before it stay done, each one its own undo step.
public struct BatchResult: Codable, Equatable, Sendable {
    /// The result of each command that ran, in order.
    public var results: [CommandResult]
    public var error: APIError?
    /// The index in the list of the command that failed.
    public var failedIndex: Int?

    public init(results: [CommandResult], error: APIError?, failedIndex: Int?) {
        self.results = results
        self.error = error
        self.failedIndex = failedIndex
    }
}
