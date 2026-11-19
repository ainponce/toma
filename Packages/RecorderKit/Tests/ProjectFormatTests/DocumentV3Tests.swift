// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Testing
// @testable for `ProjectJSON.compactEncoder()`, the encoder a `JSONValue` goes through.
@testable import ProjectFormat

private func ns(_ nanoseconds: UInt64) -> HostTime { HostTime(nanoseconds: nanoseconds) }

private func parsed(_ text: String) throws -> JSONValue {
    try ProjectJSON.decoder().decode(JSONValue.self, from: Data(text.utf8))
}

private func compact(_ value: some Encodable) throws -> String {
    String(decoding: try ProjectJSON.compactEncoder().encode(value), as: UTF8.self)
}

private func pretty(_ value: some Encodable) throws -> String {
    String(decoding: try ProjectJSON.encoder().encode(value), as: UTF8.self)
}

private func pointer(_ string: String) throws -> JSONPointer { try JSONPointer(string) }

/// The design example (`DesignExample`) in `documentVersion` 3 with every field of phase 2 away from its legacy value
/// (phase 2 design §8): a transcription of two words, the second starting a caption; the Classic captions at the top; a
/// blur block with two keys; every key on screen; the screen following the cursor in a light iPhone; the camera without
/// its background, framed by hand, with a custom look 40 ms late; the volume normalized and the microphone cleaned.
enum DocumentV3Example {
    static let lut = "assets/5f0c3a2e9b1d4c7a8e6f0b2d4a6c8e0f1a3b5c7d9e1f2a4b6c8d0e2f4a6b8c0d.cube"

    static let document: EditDocument = {
        var document = DesignExample.document
        document.transcript = Transcript(
            language: "es-AR", engine: "speechTranscriber-1",
            takes: [
                TranscriptTake(
                    take: "take-001", track: "mic",
                    words: [
                        TranscriptWord(start: ns(81_235_000_000_000), end: ns(81_235_400_000_000), text: "Hola,"),
                        TranscriptWord(start: ns(81_235_500_000_000), end: ns(81_236_000_000_000), text: "mundo.", breakBefore: true),
                    ]),
            ])
        document.captions = CaptionPlan(
            show: true,
            style: CaptionStyle(
                preset: .classic, size: .large, position: .top, uppercase: true, highlight: false, highlightColor: RGBA(0.2, 0.6, 1, 1)))
        document.privacy = PrivacyPlan(blocks: [
            PrivacyBlock(
                id: "p-5e1d0c2a", take: "take-001", start: ns(81_250_000_000_000), end: ns(81_253_000_000_000), effect: .pixelate,
                strength: 0.8, color: RGBA(0.1, 0.1, 0.1, 1), rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.4, height: 0.25),
                keys: [
                    RectKey(t: ns(81_250_000_000_000), rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.4, height: 0.25)),
                    RectKey(t: ns(81_252_000_000_000), rect: NormalizedRect(x: 0.3, y: 0.5, width: 0.4, height: 0.25)),
                ],
                origin: .email),
        ])
        document.keys = KeyOverlayPlan(mode: .all, position: .top, size: .small)
        document.style.reframe = .followCursor
        document.style.frame = .device(DeviceFrame(model: .iPhone, finish: .light))
        document.camera.background = .removed
        document.camera.framing = CameraFraming(mode: .manual, center: NormalizedPoint(x: 0.4, y: 0.35), zoom: 1.8)
        document.camera.look = CameraColor(preset: .custom, lut: lut, intensity: 0.75)
        document.camera.syncOffset = 40_000_000
        document.audio.normalize = true
        document.audio.tracks["take-001/mic"]?.cleanup = 0.6
        return document
    }()

    /// The example as `ProjectJSON.encoder()` writes it, as in `docs/format/README.md`.
    static let canonical = """
        {
          "aspect" : "16:9",
          "audio" : {
            "limiter" : true,
            "normalize" : true,
            "tracks" : {
              "take-001/mic" : {
                "cleanup" : 0.6,
                "gain" : 1,
                "muted" : false
              },
              "take-001/system-audio" : {
                "cleanup" : 0,
                "gain" : 0.8,
                "muted" : false
              }
            }
          },
          "camera" : {
            "background" : "removed",
            "border" : {
              "color" : [
                1,
                1,
                1,
                1
              ],
              "width" : 0
            },
            "changes" : [
              {
                "id" : "k-1c2d0a9e",
                "origin" : "recorded",
                "style" : {
                  "anchor" : "topLeading",
                  "shape" : "circle",
                  "size" : 0.24
                },
                "t" : 81290000000000,
                "take" : "take-001"
              }
            ],
            "framing" : {
              "center" : {
                "x" : 0.4,
                "y" : 0.35
              },
              "mode" : "manual",
              "zoom" : 1.8
            },
            "initial" : {
              "take-001" : {
                "anchor" : "bottomTrailing",
                "shape" : "circle",
                "size" : 0.24
              }
            },
            "layout" : {
              "kind" : "bubble"
            },
            "layoutRules" : "cameraLayout-1",
            "layouts" : [

            ],
            "look" : {
              "intensity" : 0.75,
              "lut" : "assets/5f0c3a2e9b1d4c7a8e6f0b2d4a6c8e0f1a3b5c7d9e1f2a4b6c8d0e2f4a6b8c0d.cube",
              "preset" : "custom"
            },
            "mirror" : false,
            "shadow" : 0,
            "show" : true,
            "sizeReference" : "height",
            "spring" : {
              "damping" : 0.95,
              "response" : 0.5
            },
            "syncOffset" : 40000000
          },
          "captions" : {
            "show" : true,
            "style" : {
              "highlight" : false,
              "highlightColor" : [
                0.2,
                0.6,
                1,
                1
              ],
              "position" : "top",
              "preset" : "classic",
              "size" : "large",
              "uppercase" : true
            }
          },
          "cursor" : {
            "clickEffect" : "ripple-1",
            "clickSound" : "none",
            "clickSoundGain" : 0.5,
            "hideWhenIdle" : true,
            "idleDelay" : 2,
            "motionBlur" : 0.5,
            "scale" : 1.5,
            "show" : true,
            "smoothing" : {
              "damping" : 1,
              "response" : 0.16
            },
            "style" : "system"
          },
          "documentVersion" : 3,
          "frameRate" : 60,
          "keys" : {
            "mode" : "all",
            "position" : "top",
            "size" : "small"
          },
          "logSequence" : 128,
          "privacy" : {
            "blocks" : [
              {
                "color" : [
                  0.1,
                  0.1,
                  0.1,
                  1
                ],
                "effect" : "pixelate",
                "end" : 81253000000000,
                "id" : "p-5e1d0c2a",
                "keys" : [
                  {
                    "rect" : {
                      "height" : 0.25,
                      "width" : 0.4,
                      "x" : 0.1,
                      "y" : 0.2
                    },
                    "t" : 81250000000000
                  },
                  {
                    "rect" : {
                      "height" : 0.25,
                      "width" : 0.4,
                      "x" : 0.3,
                      "y" : 0.5
                    },
                    "t" : 81252000000000
                  }
                ],
                "origin" : "email",
                "rect" : {
                  "height" : 0.25,
                  "width" : 0.4,
                  "x" : 0.1,
                  "y" : 0.2
                },
                "start" : 81250000000000,
                "strength" : 0.8,
                "take" : "take-001"
              }
            ]
          },
          "screens" : {
            "changes" : [
              {
                "id" : "p-9a01b2c3",
                "origin" : "auto",
                "t" : 81260000000000,
                "take" : "take-001",
                "track" : "display-2"
              }
            ],
            "initial" : {
              "take-001" : "display-1"
            },
            "planner" : "screenFollow-1"
          },
          "sequence" : [
            {
              "end" : 81276901234567,
              "id" : "c-00a1b2c3",
              "speed" : 1,
              "start" : 81234567890123,
              "take" : "take-001"
            },
            {
              "end" : 81334000000000,
              "id" : "c-00d4e5f6",
              "speed" : 2,
              "start" : 81277458000000,
              "take" : "take-001"
            }
          ],
          "style" : {
            "background" : {
              "type" : "wallpaper",
              "wallpaper" : "aurora-1"
            },
            "backgroundBlur" : 0,
            "cornerRadius" : 0.012,
            "frame" : {
              "finish" : "light",
              "model" : "iPhone",
              "type" : "device"
            },
            "geometryTransition" : "spring",
            "padding" : 0.08,
            "reframe" : "followCursor",
            "screenSampling" : "mipmapped",
            "shadow" : 0.6
          },
          "transcript" : {
            "engine" : "speechTranscriber-1",
            "language" : "es-AR",
            "takes" : [
              {
                "take" : "take-001",
                "track" : "mic",
                "words" : [
                  {
                    "end" : 81235400000000,
                    "start" : 81235000000000,
                    "text" : "Hola,"
                  },
                  {
                    "breakBefore" : true,
                    "end" : 81236000000000,
                    "start" : 81235500000000,
                    "text" : "mundo."
                  }
                ]
              }
            ]
          },
          "zoom" : {
            "auto" : {
              "depth" : 2,
              "enabled" : true,
              "follow" : true,
              "groupGap" : 2.5,
              "holdWhileTyping" : true,
              "leadIn" : 0.5,
              "leadOut" : 1,
              "planner" : "autoZoom-1",
              "triggers" : "clicks"
            },
            "motionBlur" : 0.5,
            "regions" : [
              {
                "end" : 81245000000000,
                "focus" : {
                  "type" : "follow"
                },
                "id" : "z-3fa2b1c0",
                "instant" : false,
                "origin" : "auto",
                "start" : 81241000000000,
                "take" : "take-001"
              },
              {
                "depth" : 1.6,
                "end" : 81300000000000,
                "focus" : {
                  "type" : "fixed",
                  "x" : 0.31,
                  "y" : 0.72
                },
                "id" : "z-7e11d0aa",
                "instant" : false,
                "origin" : "user",
                "start" : 81296000000000,
                "take" : "take-001"
              }
            ],
            "show" : true,
            "spring" : {
              "damping" : 1,
              "response" : 0.7
            },
            "suppressed" : [
              {
                "end" : 81320000000000,
                "start" : 81318000000000,
                "take" : "take-001"
              }
            ]
          }
        }
        """
}

extension JSONValue {
    /// The member `key` of an object; `nil` removes it. Reading or writing it on anything else does nothing.
    fileprivate subscript(key: String) -> JSONValue? {
        get {
            guard case let .object(members) = self else { return nil }
            return members[key]
        }
        set {
            guard case var .object(members) = self else { return }
            members[key] = newValue
            self = .object(members)
        }
    }
}

// MARK: - The document of version 3

@Test func version3ExampleRoundTripsByteForByte() throws {
    let document = DocumentV3Example.document
    #expect(document.documentVersion == 3)
    #expect(EditDocument.currentVersion == 3)
    #expect(try pretty(document) == DocumentV3Example.canonical)
    #expect(try EditDocument.decode(Data(DocumentV3Example.canonical.utf8)) == document)
    #expect(try EditDocument.decode(json: parsed(DocumentV3Example.canonical)) == document)
    // Compact, as a `create` line holds it, too.
    #expect(try EditDocument.decode(ProjectJSON.compactEncoder().encode(document)) == document)
    let create = EditLogEntry.create(seq: 1, document: document, app: AppInfo(name: "Toma", version: "0.4.0"))
    #expect(try EditLogEntry(jsonLine: create.jsonLine()) == create)
    // Everything of phase 2 is away from its legacy value.
    #expect(document.transcript != nil)
    #expect(document.captions != .legacy)
    #expect(document.privacy != .legacy)
    #expect(document.keys != .legacy)
    #expect(document.camera.framing != .legacy)
    #expect(document.camera.look != .natural)
}

@Test func defaultsAreLeftOut() throws {
    // A legacy word, look and document: no `breakBefore`, `lut` nor `transcript`, and never `null`.
    let word = TranscriptWord(start: ns(1_000), end: ns(2_000), text: "hola")
    #expect(!word.breakBefore)
    #expect(try compact(word) == #"{"end":2000,"start":1000,"text":"hola"}"#)
    #expect(try compact(TranscriptWord(start: ns(1_000), end: ns(2_000), text: "hola", breakBefore: true))
        == #"{"breakBefore":true,"end":2000,"start":1000,"text":"hola"}"#)
    #expect(try ProjectJSON.decoder().decode(TranscriptWord.self, from: Data(#"{"end":2000,"start":1000,"text":"hola"}"#.utf8)) == word)
    #expect(try compact(CameraColor.natural) == #"{"intensity":1,"preset":"natural"}"#)
    var document = DesignExample.document
    #expect(document.transcript == nil)
    let text = try pretty(document)
    #expect(!text.contains("\"transcript\""))
    #expect(!text.contains("\"lut\""))
    #expect(!text.contains("\"breakBefore\""))
    #expect(!text.contains("null"))
    #expect(try EditDocument.decode(Data(text.utf8)) == document)
    // The rest is always written.
    for key in ["\"captions\"", "\"keys\"", "\"privacy\"", "\"reframe\"", "\"background\" : \"original\"", "\"framing\"", "\"look\"",
        "\"syncOffset\"", "\"normalize\"", "\"cleanup\""]
    {
        #expect(text.contains(key), "\(key)")
    }
    // A transcription whose words start no caption has no `breakBefore` either.
    document.transcript = Transcript(
        language: "en-US", engine: "speechTranscriber-1", takes: [TranscriptTake(take: "take-001", track: "mic", words: [word, word])])
    let transcribed = try pretty(document)
    #expect(!transcribed.contains("\"breakBefore\""))
    #expect(!transcribed.contains("null"))
    #expect(try EditDocument.decode(Data(transcribed.utf8)) == document)
}

@Test func valuesOfThePhase2Types() throws {
    #expect(CaptionPlan.legacy == CaptionPlan(show: false, style: .default))
    #expect(
        CaptionStyle.default
            == CaptionStyle(
                preset: .bold, size: .medium, position: .bottom, uppercase: false, highlight: true,
                highlightColor: RGBA(1, 214.0 / 255, 10.0 / 255, 1)))
    #expect(PrivacyPlan.legacy == PrivacyPlan(blocks: []))
    #expect(KeyOverlayPlan.legacy == KeyOverlayPlan(mode: .off, position: .bottomCenter, size: .medium))
    #expect(CameraFraming.legacy == CameraFraming(mode: .center, center: NormalizedPoint(x: 0.5, y: 0.5), zoom: 1))
    #expect(CameraFraming.zoomRange == 1...2.5)
    #expect(CameraFraming.faceZoom == 1.4)
    #expect(CameraColor.natural == CameraColor(preset: .natural, lut: nil, intensity: 1))
    #expect(NormalizedRect.unit == NormalizedRect(x: 0, y: 0, width: 1, height: 1))
    let block = PrivacyBlock(
        id: "p-00000001", take: "take-001", start: ns(1), end: ns(2), effect: .blur, rect: NormalizedRect(x: 0.3, y: 0.4, width: 0.4, height: 0.2))
    #expect(block.strength == 0.6)
    #expect(block.color == RGBA(0, 0, 0, 1))
    #expect(block.keys.isEmpty)
    #expect(block.origin == .manual)
    // The raw values are written in `edit.json`, so they never change.
    #expect(CaptionPreset.allCases.map(\.rawValue) == ["classic", "bold", "minimal"])
    #expect(OverlaySize.allCases.map(\.rawValue) == ["small", "medium", "large"])
    #expect(CaptionPosition.allCases.map(\.rawValue) == ["bottom", "top"])
    #expect(PrivacyEffect.allCases.map(\.rawValue) == ["blur", "pixelate", "fill"])
    #expect(PrivacyOrigin.allCases.map(\.rawValue) == ["manual", "email", "phone", "card", "secret", "face"])
    #expect(KeyOverlayMode.allCases.map(\.rawValue) == ["off", "shortcuts", "all"])
    #expect(KeyOverlayPosition.allCases.map(\.rawValue) == ["bottomCenter", "bottomLeading", "bottomTrailing", "top"])
    #expect(CameraBackground.allCases.map(\.rawValue) == ["original", "blurred", "removed"])
    #expect(CameraFramingMode.allCases.map(\.rawValue) == ["center", "face", "manual"])
    #expect(CameraColorPreset.allCases.map(\.rawValue) == ["natural", "warm", "cool", "vivid", "soft", "mono", "custom"])
    #expect(DeviceModel.allCases.map(\.rawValue) == ["iPhone", "iPad", "macBook"])
    #expect(Reframe.allCases.map(\.rawValue) == ["fit", "followCursor"])
    // The new fields of the types of phase 1 default to their legacy values.
    let plain = CameraPlan(show: true, initial: [:], changes: [])
    #expect(plain.background == .original && plain.framing == .legacy && plain.look == .natural && plain.syncOffset == 0)
    #expect(!AudioPlan(limiter: false, tracks: [:]).normalize)
    #expect(TrackGain(gain: 1, muted: false).cleanup == 0)
    #expect(DefaultStyle.toma.style.reframe == .fit)
}

@Test func deviceFrameIsWrittenFlat() throws {
    for model in DeviceModel.allCases {
        for finish in [FrameAppearance.dark, .light] {
            let frame = WindowFrame.device(DeviceFrame(model: model, finish: finish))
            #expect(try compact(frame) == #"{"finish":"\#(finish.rawValue)","model":"\#(model.rawValue)","type":"device"}"#)
            #expect(try ProjectJSON.decoder().decode(WindowFrame.self, from: Data(compact(frame).utf8)) == frame)
        }
    }
    #expect(try compact(WindowFrame.device(DeviceFrame(model: .iPhone, finish: .dark)))
        == #"{"finish":"dark","model":"iPhone","type":"device"}"#)
    // A device without its model or finish is no frame.
    for text in [#"{"finish":"dark","type":"device"}"#, #"{"model":"iPad","type":"device"}"#] {
        #expect(throws: DecodingError.self) { try ProjectJSON.decoder().decode(WindowFrame.self, from: Data(text.utf8)) }
    }
}

@Test func aStyleSavedInPhase1StillDecodes() throws {
    // `default-style.json` and a `.tomastyle` of phase 1 hold a stage without `reframe`: it is `fit`.
    var saved = try JSONValue(encoding: DefaultStyle.toma)
    #expect(saved["style"]?["reframe"] == .string("fit"))
    saved["style"]?["reframe"] = nil
    #expect(try ProjectJSON.decoder().decode(DefaultStyle.self, from: Data(compact(saved).utf8)) == DefaultStyle.toma)
    // In a document it is always written, and a change that takes it away is refused.
    let document = DesignExample.document
    let away = EditChange.set(path: try pointer("/style/reframe"), before: .string("fit"), after: .null)
    #expect(throws: EditChangeError.invalidDocument("/style/reframe")) { try document.applying([away]) }
}

@Test func unknownCaseIsInvalidNotNewer() throws {
    let base = try parsed(DocumentV3Example.canonical)
    let cases: [(String, (inout JSONValue) -> Void)] = [
        ("preset", { $0["captions"]?["style"]?["preset"] = .string("sepia") }),
        ("size", { $0["captions"]?["style"]?["size"] = .string("huge") }),
        ("position", { $0["captions"]?["style"]?["position"] = .string("middle") }),
        ("keys mode", { $0["keys"]?["mode"] = .string("some") }),
        ("keys position", { $0["keys"]?["position"] = .string("left") }),
        ("reframe", { $0["style"]?["reframe"] = .string("zoom") }),
        ("frame", { $0["style"]?["frame"] = .object(["finish": .string("dark"), "model": .string("watch"), "type": .string("device")]) }),
        ("finish", { $0["style"]?["frame"] = .object(["finish": .string("gold"), "model": .string("iPad"), "type": .string("device")]) }),
        ("background", { $0["camera"]?["background"] = .string("green") }),
        ("framing", { $0["camera"]?["framing"]?["mode"] = .string("tracking") }),
        ("look", { $0["camera"]?["look"]?["preset"] = .string("sepia") }),
        ("syncOffset", { $0["camera"]?["syncOffset"] = .number(0.5) }),
        ("normalize", { $0["audio"]?["normalize"] = .string("yes") }),
        ("cleanup", { $0["audio"]?["tracks"]?["take-001/mic"]?["cleanup"] = .string("lots") }),
        ("captions", { $0["captions"] = nil }),
        ("privacy", { $0["privacy"] = nil }),
        ("keys", { $0["keys"] = nil }),
        ("framing gone", { $0["camera"]?["framing"] = nil }),
        ("cleanup gone", { $0["audio"]?["tracks"]?["take-001/mic"]?["cleanup"] = nil }),
    ]
    for (name, change) in cases {
        var text = base
        change(&text)
        #expect(text != base, "\(name)")
        // A `DecodingError`, never `EditDocumentError.newerVersion`: the document is damaged, not newer.
        #expect(throws: DecodingError.self, "\(name)") { try EditDocument.decode(json: text) }
        #expect(throws: DecodingError.self, "\(name)") { try EditDocument.decode(Data(compact(text).utf8)) }
        let line = #"{"app":{"name":"Toma","version":"0.4.0"},"document":"# + (try compact(text)) + #","seq":1,"type":"create"}"#
        #expect(throws: DecodingError.self, "\(name)") { try EditLogEntry(jsonLine: line) }
    }
    // The privacy block's and the transcription's own values too.
    var effect = base
    if case var .array(blocks)? = effect["privacy"]?["blocks"] {
        blocks[0]["effect"] = .string("smudge")
        effect["privacy"]?["blocks"] = .array(blocks)
    }
    var origin = base
    if case var .array(blocks)? = origin["privacy"]?["blocks"] {
        blocks[0]["origin"] = .string("password")
        origin["privacy"]?["blocks"] = .array(blocks)
    }
    for text in [effect, origin] {
        #expect(text != base)
        #expect(throws: DecodingError.self) { try EditDocument.decode(json: text) }
    }
}

@Test func version4IsRefused() throws {
    #expect(throws: EditDocumentError.newerVersion(4)) {
        try EditDocument.decode(Data(#"{"documentVersion":4,"aspect":"4:3"}"#.utf8))
    }
    let newer = DocumentV3Example.canonical.replacingOccurrences(of: "\"documentVersion\" : 3", with: "\"documentVersion\" : 4")
    #expect(newer != DocumentV3Example.canonical)
    #expect(throws: EditDocumentError.newerVersion(4)) { try EditDocument.decode(Data(newer.utf8)) }
    #expect(throws: EditDocumentError.newerVersion(4)) { try EditDocument.decode(json: parsed(newer)) }
    // Inside the `create` of a log too, and a `migrate` to 4.
    let line = #"{"app":{"name":"Toma","version":"0.5.0"},"document":"# + (try compact(parsed(newer))) + #","seq":1,"type":"create"}"#
    #expect(throws: EditDocumentError.newerVersion(4)) { try EditLogEntry(jsonLine: line) }
    try withTemporaryDirectory { dir in
        let url = dir.appending(path: "edit-log.jsonl")
        try Data((line + "\n").utf8).write(to: url)
        #expect(throws: EditDocumentError.newerVersion(4)) { try EditLogReader.read(url) }
        let create = EditLogEntry.create(seq: 1, document: DocumentV3Example.document, app: AppInfo(name: "Toma", version: "0.4.0"))
        let migrate = try EditLogEntry.migrate(seq: 2, from: 3, to: 4).jsonLine()
        try Data((try create.jsonLine() + "\n" + migrate + "\n").utf8).write(to: url)
        #expect(throws: EditDocumentError.newerVersion(4)) { try EditLogReader.read(url) }
    }
}

// MARK: - A `set` adds and takes away an optional member (plan decision 4)

@Test func setAddsAndRemovesAnOptionalMember() throws {
    let document = DesignExample.document
    let transcript = try #require(DocumentV3Example.document.transcript)
    let add = try #require(document.setChange("/transcript", transcript))
    #expect(add == .set(path: try pointer("/transcript"), before: .null, after: try JSONValue(encoding: transcript)))
    let added = try document.applying([add])
    #expect(added.transcript == transcript)
    // Its inverse takes it away: `nil`, and no `transcript` in the JSON.
    let removed = try added.applying([add.inverse])
    #expect(removed.transcript == nil)
    #expect(removed == document)
    #expect(!(try pretty(removed)).contains("\"transcript\""))
    #expect(try JSONValue(encoding: document).applying([add, add.inverse]) == (try JSONValue(encoding: document)))
    // `setChange` with an optional `nil` gives `after: null`.
    let away = try #require(added.setChange("/transcript", Transcript?.none))
    #expect(away == add.inverse)
    #expect(document.setChange("/transcript", Transcript?.none) == nil)

    // The same for a member of an object deeper in: the look's `lut`.
    let lut = try #require(document.setChange("/camera/look/lut", DocumentV3Example.lut))
    #expect(lut == .set(path: try pointer("/camera/look/lut"), before: .null, after: .string(DocumentV3Example.lut)))
    #expect(try document.applying([lut]).camera.look.lut == DocumentV3Example.lut)
    #expect(try document.applying([lut, lut.inverse]) == document)

    // A `before` other than `null` for a member that is not there does not match.
    #expect(throws: EditChangeError.mismatch("/transcript")) {
        try document.applying([.set(path: try pointer("/transcript"), before: .object([:]), after: .null)])
    }
    // A `before` of `null` for a member that is there does not match either.
    #expect(throws: EditChangeError.mismatch("/style/padding")) {
        try document.applying([.set(path: try pointer("/style/padding"), before: .null, after: .number(0.1))])
    }
    // Taking away a member the document needs leaves no document.
    #expect(throws: EditChangeError.invalidDocument("/style/padding")) {
        try document.applying([.set(path: try pointer("/style/padding"), before: .number(0.08), after: .null)])
    }
    #expect(throws: EditChangeError.invalidDocument("/captions")) {
        try document.applying([.set(path: try pointer("/captions"), before: JSONValue(encoding: CaptionPlan.legacy), after: .null)])
    }
    // Only a member of an object that exists: not of a number, nor an element of an array.
    #expect(throws: EditChangeError.noSuchPath("/style/padding/x")) {
        try document.applying([.set(path: try pointer("/style/padding/x"), before: .null, after: .integer(1))])
    }
    #expect(throws: EditChangeError.noSuchPath("/transcript/takes")) {
        try document.applying([.set(path: try pointer("/transcript/takes"), before: .null, after: .array([]))])
    }
    #expect(throws: EditChangeError.noSuchPath("/sequence/2")) {
        try document.applying([.set(path: try pointer("/sequence/2"), before: .null, after: .integer(1))])
    }
    // A member the document has no place for is added to the JSON, but leaves no document; `setChange` never names it.
    let nothing = EditChange.set(path: try pointer("/style/nothing"), before: .null, after: .integer(1))
    #expect(throws: EditChangeError.invalidDocument("/style/nothing")) { try document.applying([nothing]) }
    #expect(document.setChange("/style/nothing", 1) == nil)
    #expect(document.setChange("/nothing", 1) == nil)
    // The document never holds a `null`: setting one is taking the member away, also for an optional of phase 1.
    var region = document
    region.zoom.regions[1].depth = nil
    let depth = try #require(document.setChange("/zoom/regions/1/depth", Double?.none))
    #expect(depth == .set(path: try pointer("/zoom/regions/1/depth"), before: .number(1.6), after: .null))
    #expect(try document.applying([depth]) == region)
}

@Test func phase2CollectionsAreArraysOfTheDocument() throws {
    #expect(EditCollection.privacyBlocks.rawValue == "/privacy/blocks")
    #expect(EditCollection.transcriptTakes.rawValue == "/transcript/takes")
    let document = DesignExample.document
    let block = try #require(DocumentV3Example.document.privacy.blocks.first)
    let added = try document.applying([document.insertChange(.privacyBlocks, at: 0, block)])
    #expect(added.privacy.blocks == [block])
    var moved = block
    moved.start = ns(81_251_000_000_000)
    let replace = try #require(added.replaceChange(.privacyBlocks, id: block.id, with: moved))
    #expect(try added.applying([replace]).privacy.blocks == [moved])
    let remove = try #require(added.removeChange(.privacyBlocks, at: 0))
    #expect(try added.applying([remove]) == document)
    // The takes of a transcription are inserted and removed once it is there; without one there is no collection.
    let take = try #require(DocumentV3Example.document.transcript?.takes.first)
    #expect(throws: EditChangeError.noSuchPath("/transcript/takes")) {
        try document.applying([document.insertChange(.transcriptTakes, at: 0, take)])
    }
    var transcribed = document
    transcribed.transcript = Transcript(language: "es-AR", engine: "speechTranscriber-1", takes: [])
    let insert = transcribed.insertChange(.transcriptTakes, at: 0, take)
    #expect(try transcribed.applying([insert]).transcript?.takes == [take])
    // A word is corrected by its pointer (plan decision 7).
    let inserted = try transcribed.applying([insert])
    let word = try #require(inserted.setChange("/transcript/takes/0/words/1/text", "mundo!"))
    #expect(try inserted.applying([word]).transcript?.takes[0].words[1].text == "mundo!")
}
