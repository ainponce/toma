// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectAPI
import ProjectFormat

/// `export_fcpxml{project, output, codec?, size?, fps?, quality?, replace?}`: the video `export_video` writes, and next to
/// it `<name>.fcpxml` (FCPXML 1.11) and `<name>.toma-metadata.json` (`metadata-1`) of it, as Export ▸ Metadata for
/// Editors writes them (fases 4 y 5 design §6.3 and §7.2). Its progress and cancellation are `export_video`'s.
struct ExportFCPXMLTool: MCPTool {
    let name = "export_fcpxml"
    var description: String {
        """
        Exports the project as export_video does (a video, never a GIF), and writes next to it <name>.fcpxml, an FCPXML \
        1.11 project for Final Cut Pro or DaVinci Resolve with the video as one clip, its chapters as chapter markers, \
        the clicks as markers and the zoom blocks as range markers, and <name>.toma-metadata.json, for After Effects, \
        Motion or a script: the cursor on every frame, the clicks, the zoom camera, the markers and the cuts, in the \
        video's pixels and frames. A .fcpxml or .toma-metadata.json already there is refused unless replace is true \
        (the video itself is replaced). The result has the three paths: path, fcpxml and metadata.
        """
    }
    var inputSchema: JSONValue {
        guard case var .object(schema) = ExportArguments.schema(gif: false),
              case var .object(properties)? = schema["properties"]
        else { return ExportArguments.schema(gif: false) }
        properties["replace"] = MCPSchema.boolean(
            "Replace a <name>.fcpxml or <name>.toma-metadata.json already next to the video (false by default: refused).")
        schema["properties"] = .object(properties)
        return .object(schema)
    }
    var annotations: JSONValue? { MCPSchema.annotations("Export a Toma project for an external editor", readOnly: false, destructive: true) }

    func call(_ arguments: JSONValue, context: MCPContext) async throws -> MCPToolResult {
        let export = try ExportArguments(arguments, tool: name, gif: false, replace: true, context: context)
        return try .json(try await export.run(kind: .externalEditor, context: context))
    }
}
