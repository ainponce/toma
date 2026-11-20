// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectAPI
import ProjectFormat
import Sharing

/// `share{project, list?}`: uploads the project's video to the storage the person set up in Toma ▸ Settings ▸ Share and
/// gives the link (`ShareRun.share`, as `toma share` does); with `list: true` it only lists the project's links
/// (`shares.json`) and connects to nothing. It never deletes: removing what is in the person's storage stays in their
/// hands (the editor or `toma share --delete`). Its progress goes as `notifications/progress` when the client asked for
/// it; cancelling the call removes what was uploaded.
struct ShareTool: MCPTool {
    let name = "share"
    let setup: ShareSetup

    init(setup: ShareSetup = .live) {
        self.setup = setup
    }

    var description: String {
        """
        Uploads the project's video (H.264, 1080p, as Toma's Share exports it, with its chapters) to the storage the \
        user set up in Toma ▸ Settings ▸ Share (their own S3-compatible bucket: R2, S3, B2 or MinIO) and returns the \
        link to a web page with the video: {id, url, public, expiresAt, bytes, createdAt}. A link made public by the \
        user's settings never expires; a signed one stops working at expiresAt (null for a public one). It can take \
        minutes: it sends notifications/progress when the call has a progressToken, and cancelling it removes what it \
        uploaded. With list: true it only lists the project's earlier links ({shares: […]}) and does not connect. \
        Without Share set up in Toma it answers notAvailable and does nothing. It never deletes a link.
        """
    }

    var inputSchema: JSONValue {
        MCPSchema.object(
            [
                "project": MCPSchema.project,
                "list": MCPSchema.boolean("true: list the project's earlier links instead of sharing. Connects to nothing."),
            ],
            required: ["project"]
        ).withoutAdditionalProperties
    }

    var annotations: JSONValue? {
        // It writes to the user's storage (and `shares.json`) and removes nothing but what a failed share left.
        .object([
            "title": .string("Share a Toma project"), "readOnlyHint": .bool(false), "destructiveHint": .bool(false),
            "openWorldHint": .bool(true),
        ])
    }

    func call(_ arguments: JSONValue, context: MCPContext) async throws -> MCPToolResult {
        let arguments = try MCPArguments(arguments, tool: name, keys: ["project", "list"])
        let project = try context.packageURL(try arguments.string("project"))
        let setup = setup, environment = context.environment
        if try arguments.optionalBool("list") ?? false {
            let records = try await context.serialized(project) { () async throws -> [ShareRecord] in
                try ShareRun.list(package: project)
            }
            return try .json(ShareListOutput(shares: records.map(ShareOutput.init)))
        }
        var progress: (@Sendable (ShareProgress) -> Void)?
        if let report = context.progress {
            progress = { value in
                report(value.fraction, value.phase == .exporting ? "Exporting" : "Uploading")
            }
        }
        let reporting = progress ?? { _ in }
        do {
            let record = try await context.serialized(project) { () async throws -> ShareRecord in
                try await ShareRun.share(package: project, setup: setup, environment: environment, progress: reporting)
            }
            return try .json(ShareOutput(record))
        } catch is CancellationError where !Task.isCancelled {
            throw APIError(.uploadFailed, "the share was cancelled: what was uploaded was removed")
        }
    }
}

extension JSONValue {
    /// This object schema with `"additionalProperties": false`.
    fileprivate var withoutAdditionalProperties: JSONValue {
        guard case var .object(members) = self else { return self }
        members["additionalProperties"] = .bool(false)
        return .object(members)
    }
}
