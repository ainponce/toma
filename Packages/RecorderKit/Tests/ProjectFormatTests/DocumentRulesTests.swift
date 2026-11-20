// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Testing
import ProjectFormat

/// The rules of the document of phase 3 beyond its decoding (phase 3 design §10, base plan decision 6): each one found
/// in a document that breaks it, and none in a document that keeps them all, of phase 3 or of phases 1 and 2.
@Suite struct DocumentRulesTests {
    private static let video = "assets/9a8b7c6d5e4f30211203f4e5d6c7b8a9.mov"
    private static let sound = "assets/1d2c3b4a59687766554433221100ffee.m4a"

    /// `DocumentV4Example`, which has every field of phase 3, with `change` made to it.
    private static func example(_ change: (inout EditDocument) -> Void) -> EditDocument {
        var document = DocumentV4Example.document
        change(&document)
        return document
    }

    /// The index of the first clip with content of the example: a frozen frame at the end of the take's last clip.
    private static let freeze = DocumentV4Example.document.sequence.firstIndex { $0.content != nil }!

    @Test func theExampleHasNoProblem() {
        #expect(DocumentRules.problems(in: DocumentV4Example.document) == [])
        #expect(DocumentRules.problems(in: DocumentV3Example.document) == [])
    }

    @Test func everyProblemIsFound() {
        let document = DocumentV4Example.document
        let (freeze, card, media) = (Self.freeze, Self.freeze + 1, Self.freeze + 2)
        let ids = document.sequence.map(\.id)
        let cases: [(name: String, document: EditDocument, problems: [DocumentProblem])] = [
            ("not a point", Self.example { $0.sequence[freeze].end = $0.sequence[freeze].end.adding(seconds: 1) },
             [.contentNotAPoint(clip: ids[freeze])]),
            ("a point inside the clip before it", Self.example { doc in
                let start = doc.sequence[freeze].start.adding(seconds: -1)
                for k in freeze...media {
                    doc.sequence[k].start = start
                    doc.sequence[k].end = start
                }
            }, [.outOfOrder(clip: ids[freeze]), .outOfOrder(clip: ids[card]), .outOfOrder(clip: ids[media])]),
            // The second clip's J cut goes with it to the first place, where no cut moves.
            ("clips swapped", Self.example { $0.sequence.swapAt(0, 1) },
             [.audioShiftOutOfRange(clip: ids[1]), .outOfOrder(clip: ids[0])]),
            ("an L cut past half the clip", Self.example { $0.sequence[1].audioShift = 30_000_000_000 },
             [.audioShiftOutOfRange(clip: ids[1])]),
            ("a cut moved at the first clip", Self.example { $0.sequence[0].audioShift = 1 }, [.audioShiftOutOfRange(clip: ids[0])]),
            ("a cut moved after a content clip", Self.example { doc in
                doc.sequence.append(Clip(
                    id: "c-0fedcba9", take: "take-001", start: doc.sequence[media].start, end: doc.sequence[media].start.adding(seconds: 2),
                    speed: 1, audioShift: -100_000_000))
            }, [.audioShiftOutOfRange(clip: "c-0fedcba9")]),
            ("a cut moved at a content clip", Self.example { $0.sequence[card].audioShift = 5 }, [.audioShiftOutOfRange(clip: ids[card])]),
            ("a frozen frame too short", Self.example { $0.sequence[freeze].content = .freeze(duration: 99_999_999) },
             [.contentDuration(clip: ids[freeze])]),
            ("a card too long", Self.example { doc in
                guard case let .card(title, _) = doc.sequence[card].content else { return }
                doc.sequence[card].content = .card(title, duration: 60_000_000_001)
            }, [.contentDuration(clip: ids[card])]),
            ("a media clip of no length", Self.example { doc in
                doc.sequence[media].content = .media(MediaClip(asset: Self.video, start: 5, end: 5))
            }, [.contentDuration(clip: ids[media])]),
            ("a media clip outside assets", Self.example { doc in
                doc.sequence[media].content = .media(MediaClip(asset: "takes/take-001/display-1/segment-000001.mov", start: 0, end: 5))
            }, [.assetOutsideAssets("takes/take-001/display-1/segment-000001.mov")]),
            // In `assets/`, but not a clip: no name of its kind.
            ("a media clip named by no hash", Self.example { doc in
                doc.sequence[media].content = .media(MediaClip(asset: "assets/x", start: 0, end: 5))
            }, [.assetOutsideAssets("assets/x")]),
            ("a media clip that is an image", Self.example { doc in
                doc.sequence[media].content = .media(MediaClip(asset: DocumentV4Example.image, start: 0, end: 5))
            }, [.assetOutsideAssets(DocumentV4Example.image)]),
            ("an image annotation that is a clip", Self.example { doc in
                guard let k = doc.annotations.items.firstIndex(where: { if case .image = $0.kind { true } else { false } }) else { return }
                doc.annotations.items[k].kind = .image(ImageAnnotation(asset: Self.video, fit: .fit))
            }, [.assetOutsideAssets(Self.video)]),
            ("a clip annotation that is a sound", Self.example { doc in
                guard let k = doc.annotations.items.firstIndex(where: { if case .clip = $0.kind { true } else { false } }) else { return }
                doc.annotations.items[k].kind = .clip(ClipAnnotation(asset: Self.sound, start: 0, end: 1))
            }, [.assetOutsideAssets(Self.sound)]),
            ("a theme that is a clip", Self.example { $0.music.items[0].source = Self.video }, [.assetOutsideAssets(Self.video)]),
            ("an image annotation outside assets", Self.example { doc in
                guard let k = doc.annotations.items.firstIndex(where: { if case .image = $0.kind { true } else { false } }) else { return }
                doc.annotations.items[k].kind = .image(ImageAnnotation(asset: "assets/../edit.json", fit: .fit))
            }, [.assetOutsideAssets("assets/../edit.json")]),
            ("a clip annotation anchored to the take", Self.example { doc in
                guard let k = doc.annotations.items.firstIndex(where: { if case .clip = $0.kind { true } else { false } }) else { return }
                doc.annotations.items[k].anchor = .content(take: "take-001", start: doc.sequence[0].start, end: doc.sequence[0].end)
            }, [.clipAnnotationAnchoredToContent(annotation: "a-708192a3")]),
            ("a clip annotation outside assets", Self.example { doc in
                guard let k = doc.annotations.items.firstIndex(where: { if case .clip = $0.kind { true } else { false } }) else { return }
                doc.annotations.items[k].kind = .clip(ClipAnnotation(asset: "/Users/someone/Movies/a.mov", start: 0, end: 1))
            }, [.assetOutsideAssets("/Users/someone/Movies/a.mov")]),
            ("a theme from elsewhere", Self.example { $0.music.items[0].source = "file:///tmp/a.mp3" },
             [.assetOutsideAssets("file:///tmp/a.mp3")]),
            ("a theme of another library", Self.example { $0.music.items[0].source = "library:music-2/calma" },
             [.assetOutsideAssets("library:music-2/calma")]),
        ]
        for (name, document, problems) in cases {
            #expect(DocumentRules.problems(in: document) == problems, "\(name)")
        }
        #expect(document == DocumentV4Example.document)
    }

    @Test func assetPathsAndMusicSources() {
        let hash = "9a8b7c6d5e4f30211203f4e5d6c7b8a9"
        // Each kind its own names, in `assets/` alone.
        let kinds: [(PackageFileKind, valid: [String], other: [String])] = [
            (.video, ["mov", "mp4", "m4v"], ["png", "m4a", "cube", "MOV", "avi"]),
            (.asset, ["png", "jpg", "heic", "tiff"], ["mov", "m4a", "gif", "PNG"]),
            (.audio, ["m4a", "mp3", "wav", "aiff", "caf"], ["mov", "png", "aif"]),
            (.lut, ["cube"], ["png", "mov"]),
        ]
        for (kind, valid, other) in kinds {
            for ext in valid { #expect(DocumentRules.isAssetPath("assets/\(hash).\(ext)", as: kind), "\(kind) \(ext)") }
            for ext in other { #expect(!DocumentRules.isAssetPath("assets/\(hash).\(ext)", as: kind), "\(kind) \(ext)") }
            for path in [
                "", "assets/", "assets/x", "assets/.", "assets/..", "assets/a/\(hash).\(valid[0])", "assets//\(hash).\(valid[0])",
                "/assets/\(hash).\(valid[0])", "./assets/\(hash).\(valid[0])", "Assets/\(hash).\(valid[0])",
                "assets/\(hash.uppercased()).\(valid[0])", "assets/\(hash)0.\(valid[0])", "assets/\(hash).\(valid[0])\u{0}",
                "takes/take-001/\(hash).\(valid[0])", "\(hash).\(valid[0])", "edit.json",
            ] {
                #expect(!DocumentRules.isAssetPath(path, as: kind), "\(kind) \(path)")
            }
        }
        // A kind whose files live elsewhere is never one of `assets/`.
        for kind in [PackageFileKind.cursorImage, .wallpaper, .script] {
            #expect(!DocumentRules.isAssetPath("assets/\(hash).png", as: kind))
            #expect(!DocumentRules.isAssetPath("assets/script.txt", as: kind))
        }
        // A theme plays a sound of `assets/`, or one of the library.
        #expect(DocumentRules.isMusicSource(Self.sound))
        for path in [Self.video, DocumentV4Example.image, "assets/x", "assets/\(hash).aif"] {
            #expect(!DocumentRules.isMusicSource(path), "\(path)")
        }
        for source in ["library:music-1/calma", "library:music-1/Lo-Fi-2", "library:music-1/a"] {
            #expect(DocumentRules.isMusicSource(source), "\(source)")
        }
        for source in [
            "library:music-1/", "library:music-1/a/b", "library:music-1/a.b", "library:music-1/ñandú", "library:music-2/calma",
            "library:music-1/a b", "Library:music-1/a", "music-1/a", "https://example.com/a.mp3",
        ] {
            #expect(!DocumentRules.isMusicSource(source), "\(source)")
        }
    }

    /// The documents of milestones 1b and 1c and of phase 2 of these tests keep every rule, migrated.
    @Test func documentsOfPhases1And2HaveNoProblem() throws {
        #expect(DocumentRules.problems(in: try EditDocument.decode(Data(DocumentV1Example.canonical.utf8))) == [])
        #expect(DocumentRules.problems(in: DesignExample.document) == [])
        #expect(DocumentRules.problems(in: DocumentV3Example.document) == [])
    }

    /// Every document golden 3 holds (of milestones 1b and 1c and of phase 2, as the app of `main` wrote them), read
    /// from the golden files (`TOMA_GOLDEN_3_DIR`, the folder `make golden-3` compares with) and migrated, keeps every
    /// rule: the validation never turns a project of phases 1 and 2 read-only.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_GOLDEN_3_DIR"] != nil))
    func theGoldenDocumentsHaveNoProblem() throws {
        let dir = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TOMA_GOLDEN_3_DIR"]), isDirectory: true)
        for golden in GoldenDocuments.golden3Cases {
            let url = dir.appending(path: "documents/\(golden.name).json")
            let document = try EditDocument.decode(Data(contentsOf: url))
            #expect(DocumentRules.problems(in: document) == [], "\(golden.name)")
            let map = TimeMap(sequence: document.sequence)
            #expect(map.audioStarts == map.clipOutputStarts, "\(golden.name)")
        }
    }
}
