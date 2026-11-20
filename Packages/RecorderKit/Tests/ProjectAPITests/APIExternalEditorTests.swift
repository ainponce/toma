// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing
@testable import ProjectAPI

/// The API's export for an external editor (fases 4 y 5 design §7.2; plan 4b, Task A6): the video as `.video` exports it,
/// and next to it `<name>.fcpxml` and `<name>.toma-metadata.json` of that video, as the export sheet's switch writes them;
/// files of those names already there are refused unless the request says to replace them.

private let metal = MetalCondition.isAvailable || MetalCondition.isRequired

@MainActor @Suite struct APIExternalEditorTests {
    @Test(.enabled(if: metal)) func externalEditorWritesVideoFCPXMLAndMetadata() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            let url = try await APIFixtures.package(in: dir).package.url
            let project = try await TomaProject.open(url, mode: .edit, environment: environment)
            _ = try await project.apply(.addMarker(at: 4, name: "Demo"))
            _ = try await project.apply(.addZoom(from: 2, to: 5, depth: 2, focus: nil))
            guard case var .externalEditor(settings) = try await project.format(for: ExportRequest(kind: .externalEditor)) else {
                Issue.record("not an export for an external editor")
                return
            }
            #expect(settings.editorMetadata && !settings.replacesEditorFiles)
            #expect(!settings.chapters.isEmpty)
            // Small: 320 × 180 at 10 fps.
            settings.outputSize = [320, 180]
            settings.framesPerSecond = 10

            let result = try await project.export(to: dir.appending(path: "demo"), format: .externalEditor(settings), progress: nil)
            let video = dir.appending(path: "demo.mp4"), fcpxml = dir.appending(path: "demo.fcpxml")
            let metadata = dir.appending(path: "demo.toma-metadata.json")
            #expect(result.path == video.path)
            #expect(result.fcpxml == fcpxml.path)
            #expect(result.metadata == metadata.path)
            #expect(result.format == "mp4" && result.chapters == settings.chapters.count)
            for file in [video, fcpxml, metadata] { #expect(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent)") }

            let xml = try XMLDocument(contentsOf: fcpxml)
            let root = try #require(xml.rootElement())
            #expect(root.name == "fcpxml")
            #expect(root.attribute(forName: "version")?.stringValue == "1.11")
            #expect(try xml.nodes(forXPath: "//asset-clip").count == 1)
            // Every marker the output shows is a chapter marker (design §7.2): the two recorded ones and «Demo».
            let visible = await project.markers
            #expect(visible.count == 3)
            #expect(try xml.nodes(forXPath: "//chapter-marker").count == visible.count)
            let names = try xml.nodes(forXPath: "//chapter-marker/@value").compactMap(\.stringValue)
            #expect(names.contains("Demo"))
            // The zoom block, a marker of a range.
            #expect(try xml.nodes(forXPath: "//marker").contains { ($0 as? XMLElement)?.attribute(forName: "value")?.stringValue?.hasPrefix("Zoom") == true })
            let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
            #expect(json["format"] as? String == ExternalEditorExport.metadataID)
            #expect((json["video"] as? [String: Any])?["file"] as? String == "demo.mp4")

            // Again: the files for the editor are there, and are not replaced unless asked; nothing is written.
            let before = try [fcpxml, metadata].map { try Data(contentsOf: $0) }
            try Data("old".utf8).write(to: fcpxml)
            let refused = await APIFixtures.apiError {
                _ = try await project.export(to: video, format: .externalEditor(settings), progress: nil)
            }
            #expect(refused?.code == .refused)
            #expect(refused?.message.contains("demo.fcpxml") == true)
            #expect(refused?.message.contains("replace") == true)
            #expect(try Data(contentsOf: fcpxml) == Data("old".utf8))
            #expect(try Data(contentsOf: metadata) == before[1])

            // Asked to replace them: replaced.
            var replacing = settings
            replacing.replacesEditorFiles = true
            _ = try await project.export(to: video, format: .externalEditor(replacing), progress: nil)
            #expect(try Data(contentsOf: fcpxml) == before[0])

            // A plain video never writes them, whatever its settings say.
            var plain = settings
            plain.editorMetadata = true
            let other = try await project.export(to: dir.appending(path: "plain.mp4"), format: .video(plain), progress: nil)
            #expect(other.fcpxml == nil && other.metadata == nil)
            #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "plain.fcpxml").path))
            await project.close()
        }
    }

    @Test func requestAsksToReplaceOnlyForAnExternalEditor() async throws {
        try await withTemporaryDirectory { dir in
            let environment = APIFixtures.environment(in: dir)
            let url = try await APIFixtures.package(in: dir).package.url
            let project = try await TomaProject.open(url, mode: .read, environment: environment)
            guard case let .externalEditor(asked) = try await project.format(
                for: ExportRequest(kind: .externalEditor, replacesEditorFiles: true))
            else {
                Issue.record("not an export for an external editor")
                return
            }
            #expect(asked.editorMetadata && asked.replacesEditorFiles)
            guard case let .video(video) = try await project.format(for: ExportRequest(replacesEditorFiles: true)) else {
                Issue.record("not a video")
                return
            }
            #expect(!video.editorMetadata && !video.replacesEditorFiles)
            // The request reads and writes its new key, and one without it does not replace.
            let decoded = try JSONDecoder().decode(ExportRequest.self, from: Data(#"{"kind":"externalEditor"}"#.utf8))
            #expect(decoded == ExportRequest(kind: .externalEditor))
            let request = ExportRequest(kind: .externalEditor, replacesEditorFiles: true)
            #expect(try JSONDecoder().decode(ExportRequest.self, from: JSONEncoder().encode(request)) == request)
            await project.close()
        }
    }
}
