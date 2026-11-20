// SPDX-License-Identifier: GPL-3.0-or-later

/// The tools `toma mcp` offers, in the order `tools/list` gives them (fases 4 y 5 design §6.3). Only ever appended to,
/// one line each: Task A6 adds `export_fcpxml`, milestone 5a `share` and milestone 5b `suggest_chapters`, each tool in
/// a file of its own.
enum MCPToolCatalog {
    static let all: [any MCPTool] = [
        ListProjectsTool(),
        ProjectInfoTool(),
        GetTranscriptTool(),
        GetMarkersTool(),
        ApplyCommandsTool(),
        UndoTool(),
        RedoTool(),
        ExportVideoTool(),
        ShareTool(),
        SuggestChaptersTool(),
    ]
}
