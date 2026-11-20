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

    /// The element `index` of an array; writing it on anything else, or out of it, does nothing.
    fileprivate subscript(index: Int) -> JSONValue? {
        get {
            guard case let .array(elements) = self, elements.indices.contains(index) else { return nil }
            return elements[index]
        }
        set {
            guard case var .array(elements) = self, elements.indices.contains(index), let newValue else { return }
            elements[index] = newValue
            self = .array(elements)
        }
    }

    /// The value at `pointer`, `nil` if there is none.
    fileprivate func at(_ pointer: String) -> JSONValue? {
        (try? JSONPointer(pointer)).flatMap { value(at: $0) }
    }
}

/// `DocumentV3Example` in `documentVersion` 4 with every field of phase 3 away from its legacy value (phase 3 design
/// §10): after the first clip, the second with its sound 120 ms early; then, at the end of that one, a frozen frame of
/// 2 s, a title card on a colour and an imported clip at 1.5×; the second zoom a rounded loupe of 0.2, the automatic
/// ones dimming; the microphone silent for 2 s; an annotation of each kind (a lower third with its background, a curved
/// arrow, a filled shape, a callout, a step, an image over the whole video and a clip over the output); a piece of the
/// library without ducking; a named marker, hidden.
enum DocumentV4Example {
    static let image = "assets/0f1e2d3c4b5a69788796a5b4c3d2e1f0.png"
    static let video = "assets/9a8b7c6d5e4f30211203f4e5d6c7b8a9.mov"
    static let media = "assets/1d2c3b4a59687766554433221100ffee.mp4"
    static let point = ns(81_334_000_000_000)

    static let document: EditDocument = {
        var document = DocumentV3Example.document
        document.sequence[1].audioShift = -120_000_000
        document.sequence += [
            Clip(id: "c-00f0e1d2", take: "take-001", start: point, end: point, speed: 1, content: .freeze(duration: ClipContent.freezeDuration)),
            Clip(
                id: "c-01a2b3c4", take: "take-001", start: point, end: point, speed: 1,
                content: .card(
                    TitleCard(title: "Capítulo 2", subtitle: "Lo que sigue", style: .large, background: .color(RGBA(0.1, 0.1, 0.12, 1))),
                    duration: ClipContent.cardDuration)),
            Clip(
                id: "c-02b3c4d5", take: "take-001", start: point, end: point, speed: 1,
                content: .media(MediaClip(asset: media, start: 0, end: 4_000_000_000, speed: 1.5, volume: -6))),
        ]
        document.zoom.auto.mode = .dim
        document.zoom.regions[1].mode = .loupe
        document.zoom.regions[1].loupe = LoupeStyle(radius: 0.2, shape: .roundedRect)
        document.audio.tracks["take-001/mic"]?.ranges = [
            GainRange(id: "g-4b5c6d7e", take: "take-001", start: ns(81_250_000_000_000), end: ns(81_252_000_000_000), gain: GainRange.silence)
        ]
        document.annotations = AnnotationPlan(items: [
            Annotation(
                id: "a-1a2b3c4d", anchor: .content(take: "take-001", start: ns(81_236_000_000_000), end: ns(81_240_000_000_000)), layer: 0,
                kind: .text(TextAnnotation(string: "Ana Pérez", preset: .lowerThird)),
                rect: NormalizedRect(x: 0.05, y: 0.78, width: 0.4, height: 0.12)),
            Annotation(
                id: "a-2b3c4d5e", anchor: .content(take: "take-001", start: ns(81_241_000_000_000), end: ns(81_244_000_000_000)), layer: 1,
                kind: .arrow(
                    ArrowAnnotation(from: NormalizedPoint(x: 0.2, y: 0.3), to: NormalizedPoint(x: 0.45, y: 0.5), curve: 0.4, head: .filled)),
                rect: NormalizedRect(x: 0.2, y: 0.3, width: 0.25, height: 0.2), enter: .draw, exit: .none),
            Annotation(
                id: "a-3c4d5e6f", anchor: .output(start: 5_000_000_000, end: 8_000_000_000), layer: 2,
                kind: .shape(ShapeAnnotation(shape: .roundedRect, stroke: RGBA(1, 1, 1, 1), width: 0.005, fill: RGBA(1, 1, 1, 0.25))),
                rect: NormalizedRect(x: 0.6, y: 0.1, width: 0.3, height: 0.2), opacity: 0.9),
            Annotation(
                id: "a-4d5e6f70", anchor: .content(take: "take-001", start: ns(81_246_000_000_000), end: ns(81_249_000_000_000)), layer: 3,
                kind: .callout(
                    CalloutAnnotation(
                        text: TextAnnotation(
                            string: "Acá", preset: .label, font: .rounded, weight: .bold, size: 0.04, color: RGBA(0.1, 0.1, 0.1, 1),
                            fill: RGBA(1, 1, 1, 0.9), align: .leading),
                        target: NormalizedPoint(x: 0.62, y: 0.41))),
                rect: NormalizedRect(x: 0.5, y: 0.2, width: 0.2, height: 0.08), enter: .pop),
            Annotation(
                id: "a-5e6f7081", anchor: .content(take: "take-001", start: ns(81_246_000_000_000), end: ns(81_249_000_000_000)), layer: 4,
                kind: .step(StepAnnotation()), rect: NormalizedRect(x: 0.6, y: 0.38, width: 0.04, height: 0.07)),
            Annotation(
                id: "a-6f708192", anchor: .whole, layer: 0, kind: .image(ImageAnnotation(asset: image, fit: .fit, corner: 0.02, shadow: true)),
                rect: NormalizedRect(x: 0.85, y: 0.05, width: 0.1, height: 0.1), rotation: -5, opacity: 0.8),
            Annotation(
                id: "a-708192a3", anchor: .output(start: 10_000_000_000, end: 14_000_000_000), layer: 1,
                kind: .clip(ClipAnnotation(asset: video, start: 1_000_000_000, end: 5_000_000_000, volume: -3, corner: 0.03, shadow: true)),
                rect: NormalizedRect(x: 0.65, y: 0.6, width: 0.3, height: 0.3)),
        ])
        document.music = MusicPlan(
            items: [
                MusicItem(
                    id: "mu-1f2e3d4c", source: "library:music-1/calma", start: 0, end: 60_000_000_000, offset: 15_000_000_000, gain: -18,
                    fadeIn: 500_000_000, fadeOut: 3_000_000_000, loop: false)
            ],
            ducking: Ducking(enabled: false))
        document.markers = MarkerPlan(items: [
            Marker(id: "m-0a1b2c3d", take: "take-001", t: ns(81_262_000_000_000), name: "Demo", origin: .recorded, hidden: true)
        ])
        return document
    }()

    /// The example as `ProjectJSON.encoder()` writes it, as in `docs/format/README.md`.
    static let canonical = """
        {
          "annotations" : {
            "items" : [
              {
                "anchor" : {
                  "end" : 81240000000000,
                  "start" : 81236000000000,
                  "take" : "take-001",
                  "type" : "content"
                },
                "enter" : "fade",
                "exit" : "fade",
                "id" : "a-1a2b3c4d",
                "kind" : {
                  "align" : "center",
                  "color" : [
                    1,
                    1,
                    1,
                    1
                  ],
                  "fill" : [
                    0,
                    0,
                    0,
                    0.7
                  ],
                  "font" : "system",
                  "preset" : "lowerThird",
                  "size" : 0.05,
                  "string" : "Ana Pérez",
                  "type" : "text",
                  "weight" : "semibold"
                },
                "layer" : 0,
                "opacity" : 1,
                "rect" : {
                  "height" : 0.12,
                  "width" : 0.4,
                  "x" : 0.05,
                  "y" : 0.78
                },
                "rotation" : 0
              },
              {
                "anchor" : {
                  "end" : 81244000000000,
                  "start" : 81241000000000,
                  "take" : "take-001",
                  "type" : "content"
                },
                "enter" : "draw",
                "exit" : "none",
                "id" : "a-2b3c4d5e",
                "kind" : {
                  "color" : [
                    1,
                    0.27058823529411763,
                    0.22745098039215686,
                    1
                  ],
                  "curve" : 0.4,
                  "from" : {
                    "x" : 0.2,
                    "y" : 0.3
                  },
                  "head" : "filled",
                  "to" : {
                    "x" : 0.45,
                    "y" : 0.5
                  },
                  "type" : "arrow",
                  "width" : 0.006
                },
                "layer" : 1,
                "opacity" : 1,
                "rect" : {
                  "height" : 0.2,
                  "width" : 0.25,
                  "x" : 0.2,
                  "y" : 0.3
                },
                "rotation" : 0
              },
              {
                "anchor" : {
                  "end" : 8000000000,
                  "start" : 5000000000,
                  "type" : "output"
                },
                "enter" : "fade",
                "exit" : "fade",
                "id" : "a-3c4d5e6f",
                "kind" : {
                  "fill" : [
                    1,
                    1,
                    1,
                    0.25
                  ],
                  "shape" : "roundedRect",
                  "stroke" : [
                    1,
                    1,
                    1,
                    1
                  ],
                  "type" : "shape",
                  "width" : 0.005
                },
                "layer" : 2,
                "opacity" : 0.9,
                "rect" : {
                  "height" : 0.2,
                  "width" : 0.3,
                  "x" : 0.6,
                  "y" : 0.1
                },
                "rotation" : 0
              },
              {
                "anchor" : {
                  "end" : 81249000000000,
                  "start" : 81246000000000,
                  "take" : "take-001",
                  "type" : "content"
                },
                "enter" : "pop",
                "exit" : "fade",
                "id" : "a-4d5e6f70",
                "kind" : {
                  "target" : {
                    "x" : 0.62,
                    "y" : 0.41
                  },
                  "text" : {
                    "align" : "leading",
                    "color" : [
                      0.1,
                      0.1,
                      0.1,
                      1
                    ],
                    "fill" : [
                      1,
                      1,
                      1,
                      0.9
                    ],
                    "font" : "rounded",
                    "preset" : "label",
                    "size" : 0.04,
                    "string" : "Acá",
                    "weight" : "bold"
                  },
                  "type" : "callout"
                },
                "layer" : 3,
                "opacity" : 1,
                "rect" : {
                  "height" : 0.08,
                  "width" : 0.2,
                  "x" : 0.5,
                  "y" : 0.2
                },
                "rotation" : 0
              },
              {
                "anchor" : {
                  "end" : 81249000000000,
                  "start" : 81246000000000,
                  "take" : "take-001",
                  "type" : "content"
                },
                "enter" : "fade",
                "exit" : "fade",
                "id" : "a-5e6f7081",
                "kind" : {
                  "color" : [
                    1,
                    0.27058823529411763,
                    0.22745098039215686,
                    1
                  ],
                  "type" : "step"
                },
                "layer" : 4,
                "opacity" : 1,
                "rect" : {
                  "height" : 0.07,
                  "width" : 0.04,
                  "x" : 0.6,
                  "y" : 0.38
                },
                "rotation" : 0
              },
              {
                "anchor" : {
                  "type" : "whole"
                },
                "enter" : "fade",
                "exit" : "fade",
                "id" : "a-6f708192",
                "kind" : {
                  "asset" : "assets/0f1e2d3c4b5a69788796a5b4c3d2e1f0.png",
                  "corner" : 0.02,
                  "fit" : "fit",
                  "shadow" : true,
                  "type" : "image"
                },
                "layer" : 0,
                "opacity" : 0.8,
                "rect" : {
                  "height" : 0.1,
                  "width" : 0.1,
                  "x" : 0.85,
                  "y" : 0.05
                },
                "rotation" : -5
              },
              {
                "anchor" : {
                  "end" : 14000000000,
                  "start" : 10000000000,
                  "type" : "output"
                },
                "enter" : "fade",
                "exit" : "fade",
                "id" : "a-708192a3",
                "kind" : {
                  "asset" : "assets/9a8b7c6d5e4f30211203f4e5d6c7b8a9.mov",
                  "corner" : 0.03,
                  "end" : 5000000000,
                  "muted" : false,
                  "shadow" : true,
                  "start" : 1000000000,
                  "type" : "clip",
                  "volume" : -3
                },
                "layer" : 1,
                "opacity" : 1,
                "rect" : {
                  "height" : 0.3,
                  "width" : 0.3,
                  "x" : 0.65,
                  "y" : 0.6
                },
                "rotation" : 0
              }
            ]
          },
          "aspect" : "16:9",
          "audio" : {
            "limiter" : true,
            "normalize" : true,
            "tracks" : {
              "take-001/mic" : {
                "cleanup" : 0.6,
                "gain" : 1,
                "muted" : false,
                "ranges" : [
                  {
                    "end" : 81252000000000,
                    "gain" : -120,
                    "id" : "g-4b5c6d7e",
                    "start" : 81250000000000,
                    "take" : "take-001"
                  }
                ]
              },
              "take-001/system-audio" : {
                "cleanup" : 0,
                "gain" : 0.8,
                "muted" : false,
                "ranges" : [

                ]
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
          "documentVersion" : 4,
          "frameRate" : 60,
          "keys" : {
            "mode" : "all",
            "position" : "top",
            "size" : "small"
          },
          "logSequence" : 128,
          "markers" : {
            "items" : [
              {
                "hidden" : true,
                "id" : "m-0a1b2c3d",
                "name" : "Demo",
                "origin" : "recorded",
                "t" : 81262000000000,
                "take" : "take-001"
              }
            ]
          },
          "music" : {
            "ducking" : {
              "amount" : -12,
              "attack" : 0.3,
              "enabled" : false,
              "release" : 0.8
            },
            "items" : [
              {
                "end" : 60000000000,
                "fadeIn" : 500000000,
                "fadeOut" : 3000000000,
                "gain" : -18,
                "id" : "mu-1f2e3d4c",
                "loop" : false,
                "offset" : 15000000000,
                "source" : "library:music-1/calma",
                "start" : 0
              }
            ]
          },
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
              "audioShift" : 0,
              "end" : 81276901234567,
              "id" : "c-00a1b2c3",
              "speed" : 1,
              "start" : 81234567890123,
              "take" : "take-001"
            },
            {
              "audioShift" : -120000000,
              "end" : 81334000000000,
              "id" : "c-00d4e5f6",
              "speed" : 2,
              "start" : 81277458000000,
              "take" : "take-001"
            },
            {
              "audioShift" : 0,
              "content" : {
                "duration" : 2000000000,
                "type" : "freeze"
              },
              "end" : 81334000000000,
              "id" : "c-00f0e1d2",
              "speed" : 1,
              "start" : 81334000000000,
              "take" : "take-001"
            },
            {
              "audioShift" : 0,
              "content" : {
                "card" : {
                  "background" : {
                    "color" : [
                      0.1,
                      0.1,
                      0.12,
                      1
                    ],
                    "type" : "color"
                  },
                  "style" : "large",
                  "subtitle" : "Lo que sigue",
                  "textColor" : [
                    1,
                    1,
                    1,
                    1
                  ],
                  "title" : "Capítulo 2"
                },
                "duration" : 3000000000,
                "type" : "card"
              },
              "end" : 81334000000000,
              "id" : "c-01a2b3c4",
              "speed" : 1,
              "start" : 81334000000000,
              "take" : "take-001"
            },
            {
              "audioShift" : 0,
              "content" : {
                "media" : {
                  "asset" : "assets/1d2c3b4a59687766554433221100ffee.mp4",
                  "end" : 4000000000,
                  "speed" : 1.5,
                  "start" : 0,
                  "volume" : -6
                },
                "type" : "media"
              },
              "end" : 81334000000000,
              "id" : "c-02b3c4d5",
              "speed" : 1,
              "start" : 81334000000000,
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
              "mode" : "dim",
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
                "loupe" : {
                  "radius" : 0.2,
                  "shape" : "roundedRect"
                },
                "mode" : "loupe",
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

// MARK: - The document of version 4

@Test func version3DecodesMigratedTo4() throws {
    let v3 = try parsed(DocumentV3Example.canonical)
    #expect(v3["documentVersion"] == .integer(3))
    let document = try EditDocument.decode(Data(DocumentV3Example.canonical.utf8))
    // Of version 5 since phases 4 and 5 (`Document5Tests`): migrated through 4.
    #expect(document.documentVersion == EditDocument.currentVersion)
    #expect(DocumentMigration.reverted(try JSONValue(encoding: document), to: 4) == (try DocumentMigration.migrate(v3, from: 3)))
    #expect(document.annotations == .legacy)
    #expect(document.music == .legacy)
    #expect(document.markers == .legacy)
    #expect(document.sequence.count == 2)
    #expect(document.sequence.allSatisfy { $0.content == nil && $0.audioShift == 0 })
    #expect(document.zoom.auto.mode == .classic)
    #expect(document.zoom.regions.count == 2)
    #expect(document.zoom.regions.allSatisfy { $0.mode == nil && $0.loupe == nil })
    #expect(document.audio.tracks.count == 2)
    #expect(document.audio.tracks.values.allSatisfy { $0.ranges.isEmpty })
    #expect(document == DocumentV3Example.document)
    // Reverted, the bytes phase 2 wrote.
    let back = try #require(DocumentMigration.reverted(JSONValue(encoding: document), to: 3))
    #expect(back == v3)
    #expect(try pretty(back) == DocumentV3Example.canonical)
    // From its JSON, inside the `create` of a log of phase 2, and its version read alone.
    #expect(try EditDocument.decode(json: v3) == document)
    let line = #"{"app":{"name":"Toma","version":"0.4.0"},"document":"# + (try compact(v3)) + #","seq":1,"type":"create"}"#
    #expect(try EditLogEntry(jsonLine: line) == .create(seq: 1, document: document, app: AppInfo(name: "Toma", version: "0.4.0")))
    #expect(EditDocument.writtenVersion(of: Data(DocumentV3Example.canonical.utf8)) == 3)
}

@Test func version1And2MigrateThroughEveryStep() throws {
    let v1 = try parsed(DocumentV1Example.canonical)
    let v2 = try parsed(DesignExample.canonical)
    let migrated1 = try DocumentMigration.migrate(DocumentMigration.migrate(DocumentMigration.migrate(v1, from: 1), from: 2), from: 3)
    let migrated2 = try DocumentMigration.migrate(DocumentMigration.migrate(v2, from: 2), from: 3)
    #expect(migrated1["documentVersion"] == .integer(4))
    #expect(migrated2["documentVersion"] == .integer(4))
    #expect(try EditDocument.decode(json: v1) == (try migrated1.decoded(as: EditDocument.self)))
    #expect(try EditDocument.decode(json: v2) == (try migrated2.decoded(as: EditDocument.self)))
    #expect(try EditDocument.decode(Data(DocumentV1Example.canonical.utf8)) == DesignExample.document)
    #expect(try EditDocument.decode(Data(DesignExample.canonical.utf8)) == DesignExample.document)
    #expect(DesignExample.document.documentVersion == EditDocument.currentVersion)
    // Every step is what decoding does, and its JSON is the document's in version 4.
    #expect(migrated1 == DocumentMigration.reverted(try JSONValue(encoding: DesignExample.document), to: 4))
    #expect(migrated2 == migrated1)
}

/// What the migration from version 3 writes (phase 3 design §10, plan decision 4), as the design gives the legacy values.
private let addedFrom3: [String: JSONValue] = [
    "/annotations": .object(["items": .array([])]),
    "/markers": .object(["items": .array([])]),
    "/music": .object([
        "ducking": .object(["amount": .integer(-12), "attack": .number(0.3), "enabled": .bool(true), "release": .number(0.8)]),
        "items": .array([]),
    ]),
    "/zoom/auto/mode": .string("classic"),
]

@Test func migrationFrom3AddsOnlyItsPlaces() throws {
    // Two clips, two tracks, two regions: each clip gets its `audioShift` and each track its `ranges`, never a region.
    let v3 = try parsed(DocumentV3Example.canonical)
    let migrated = try DocumentMigration.migrate(v3, from: 3)
    #expect(migrated["documentVersion"] == .integer(4))
    #expect(DocumentMigration.addedPlaces[3] == [
        "/annotations", "/markers", "/music", "/sequence/*/audioShift", "/zoom/auto/mode", "/audio/tracks/*/ranges",
    ])
    #expect(DocumentMigration.addedPlaces.keys.sorted() == [1, 2, 3, 4])
    var rest = migrated
    rest["documentVersion"] = .integer(3)
    for (place, value) in addedFrom3 {
        #expect(migrated.at(place) == value, "\(place)")
        #expect(v3.at(place) == nil, "\(place)")
    }
    rest["annotations"] = nil
    rest["markers"] = nil
    rest["music"] = nil
    rest["zoom"]?["auto"]?["mode"] = nil
    for index in 0..<2 {
        #expect(migrated["sequence"]?[index]?["audioShift"] == .integer(0), "\(index)")
        #expect(v3["sequence"]?[index]?["audioShift"] == nil, "\(index)")
        rest["sequence"]?[index]?["audioShift"] = nil
        #expect(migrated["zoom"]?["regions"]?[index]?["mode"] == nil, "\(index)")
        #expect(migrated["zoom"]?["regions"]?[index]?["loupe"] == nil, "\(index)")
    }
    for track in ["take-001/mic", "take-001/system-audio"] {
        #expect(migrated["audio"]?["tracks"]?[track]?["ranges"] == .array([]), "\(track)")
        #expect(v3["audio"]?["tracks"]?[track]?["ranges"] == nil, "\(track)")
        rest["audio"]?["tracks"]?[track]?["ranges"] = nil
    }
    #expect(rest == v3)
    // What it writes is what the legacy values of the types encode to.
    let legacy = try JSONValue(encoding: EditDocument.legacy(take: TakeRecord(
        id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 0), tracks: []), events: []))
    for (place, value) in addedFrom3 {
        #expect(legacy.at(place) == value, "\(place)")
    }
    #expect(legacy.at("/sequence/0/audioShift") == .integer(0))
    #expect(try JSONValue(encoding: TrackGain(gain: 1, muted: false))["ranges"] == .array([]))

    // What was already there is overwritten, and a document without clips or tracks migrates.
    var handWritten = v3
    handWritten["markers"] = .string("many")
    handWritten["sequence"]?[0]?["audioShift"] = .integer(5)
    handWritten["audio"]?["tracks"]?["take-001/mic"]?["ranges"] = .array([.integer(1)])
    #expect(try DocumentMigration.migrate(handWritten, from: 3) == migrated)
    var empty = v3
    empty["sequence"] = .array([])
    empty["audio"]?["tracks"] = .object([:])
    let emptied = try DocumentMigration.migrate(empty, from: 3)
    #expect(emptied["sequence"] == .array([]))
    #expect(emptied["audio"]?["tracks"] == .object([:]))
    // One without the objects it writes in does not.
    for (missing, error) in [("zoom", "/zoom"), ("sequence", "/sequence"), ("audio", "/audio")] {
        var without = v3
        without[missing] = nil
        #expect(throws: EditChangeError.invalidDocument(error), "\(missing)") { try DocumentMigration.migrate(without, from: 3) }
    }
    var withoutAuto = v3
    withoutAuto["zoom"]?["auto"] = nil
    #expect(throws: EditChangeError.invalidDocument("/zoom/auto")) { try DocumentMigration.migrate(withoutAuto, from: 3) }
    var clipNotAnObject = v3
    clipNotAnObject["sequence"]?[1] = .integer(1)
    #expect(throws: EditChangeError.invalidDocument("/sequence/1")) { try DocumentMigration.migrate(clipNotAnObject, from: 3) }

    #expect(DocumentMigration.isAdditive(from: 3))
    // From 4 too, since phases 4 and 5 (`Document5Tests`).
    #expect(DocumentMigration.isAdditive(from: 4))
    #expect(!DocumentMigration.isAdditive(from: 5))
    for (document, version) in [(v3, 2), (v3, 4), (migrated, 3), (migrated, 5)] {
        #expect(throws: EditChangeError.invalidDocument("/documentVersion"), "\(version)") {
            try DocumentMigration.migrate(document, from: version)
        }
    }
}

@Test func migrationFrom3RefusesWhatOnly4Holds() throws {
    // A document of version 3 made by hand with a clip's content or a region's mode or loupe: version 3 has no place for
    // them, so it is damaged, never read as a document of version 4 (`reverted` refuses the same).
    let v3 = try parsed(DocumentV3Example.canonical)
    var content = v3
    content["sequence"]?[1]?["content"] = .object(["duration": .integer(2_000_000_000), "type": .string("freeze")])
    var mode = v3
    mode["zoom"]?["regions"]?[0]?["mode"] = .string("dim")
    var loupe = v3
    loupe["zoom"]?["regions"]?[1]?["loupe"] = .object(["radius": .number(0.2), "shape": .string("circle")])
    for (document, place) in [(content, "/sequence/1/content"), (mode, "/zoom/regions/0/mode"), (loupe, "/zoom/regions/1/loupe")] {
        #expect(document != v3, "\(place)")
        #expect(throws: EditChangeError.invalidDocument(place)) { try DocumentMigration.migrate(document, from: 3) }
        #expect(throws: DecodingError.self, "\(place)") { try EditDocument.decode(json: document) }
        let text = try compact(document)
        #expect(throws: DecodingError.self, "\(place)") { try EditDocument.decode(Data(text.utf8)) }
        let line = #"{"app":{"name":"Toma","version":"0.4.0"},"document":"# + text + #","seq":1,"type":"create"}"#
        #expect(throws: DecodingError.self, "\(place)") { try EditLogEntry(jsonLine: line) }
    }
}

@Test func version4ExampleRoundTripsByteForByte() throws {
    // Since phases 4 and 5 the document is of version 5 (`Document5Tests`): the example is what it is in version 4.
    let document = DocumentV4Example.document
    #expect(document.documentVersion == EditDocument.currentVersion)
    #expect(try pretty(DocumentMigration.reverted(JSONValue(encoding: document), to: 4)) == DocumentV4Example.canonical)
    #expect(try EditDocument.decode(Data(DocumentV4Example.canonical.utf8)) == document)
    #expect(try EditDocument.decode(json: parsed(DocumentV4Example.canonical)) == document)
    #expect(try EditDocument.decode(ProjectJSON.compactEncoder().encode(document)) == document)
    let create = EditLogEntry.create(seq: 1, document: document, app: AppInfo(name: "Toma", version: "0.5.0"))
    #expect(try EditLogEntry(jsonLine: create.jsonLine()) == create)
    #expect(document.heldJSON() == (try JSONValue(encoding: document)))
    // Everything of phase 3 is away from its legacy value, so no older version holds it.
    #expect(document.annotations != .legacy)
    #expect(document.music != .legacy)
    #expect(document.markers != .legacy)
    #expect(document.zoom.auto.mode != .classic)
    #expect(DocumentMigration.reverted(try JSONValue(encoding: document), to: 3) == nil)
    #expect(DocumentMigration.oldestVersion(holding: document) == 4)
    // One of each kind of annotation.
    let kinds = document.annotations.items.map { item -> String in
        switch item.kind {
        case .text: "text"
        case .arrow: "arrow"
        case .shape: "shape"
        case .callout: "callout"
        case .step: "step"
        case .image: "image"
        case .clip: "clip"
        }
    }
    #expect(kinds == ["text", "arrow", "shape", "callout", "step", "image", "clip"])
}

@Test func nilOptionalsAreLeftOut() throws {
    // A clip without content, a region without mode or loupe, a text and a shape without background.
    let clip = Clip(id: "c-00000001", take: "take-001", start: ns(1_000), end: ns(2_000), speed: 1)
    #expect(clip.content == nil && clip.audioShift == 0)
    #expect(try compact(clip) == #"{"audioShift":0,"end":2000,"id":"c-00000001","speed":1,"start":1000,"take":"take-001"}"#)
    let region = ZoomRegion(id: "z-00000001", take: "take-001", start: ns(1_000), end: ns(2_000), origin: .user, focus: .follow, instant: false)
    #expect(region.mode == nil && region.loupe == nil)
    #expect(try compact(region)
        == #"{"end":2000,"focus":{"type":"follow"},"id":"z-00000001","instant":false,"origin":"user","start":1000,"take":"take-001"}"#)
    let text = TextAnnotation(string: "hola", preset: .plain)
    #expect(text.fill == nil)
    #expect(try compact(text)
        == #"{"align":"center","color":[1,1,1,1],"font":"system","preset":"plain","size":0.05,"string":"hola","weight":"semibold"}"#)
    #expect(try compact(ShapeAnnotation(shape: .ellipse)) == #"{"shape":"ellipse","stroke":[1,0.27058823529411763,0.22745098039215686,1],"width":0.004}"#)
    // The legacy document: never `content`, `mode`, `loupe`, `fill` nor `null`.
    let legacy = try pretty(DesignExample.document)
    for key in ["\"content\"", "\"loupe\"", "\"fill\"", "null"] {
        #expect(!legacy.contains(key), "\(key)")
    }
    #expect(!legacy.contains("\"mode\" : \"loupe\""))
    #expect(try EditDocument.decode(Data(legacy.utf8)) == DesignExample.document)
    // The rest is always written.
    for key in ["\"annotations\"", "\"music\"", "\"ducking\"", "\"markers\"", "\"audioShift\"", "\"mode\" : \"classic\"", "\"ranges\""] {
        #expect(legacy.contains(key), "\(key)")
    }
    // The example has them, where they are not `nil`.
    let example = try pretty(DocumentV4Example.document)
    #expect(!example.contains("null"))
    #expect(example.components(separatedBy: "\"content\" :").count == 4)
    #expect(example.components(separatedBy: "\"loupe\" :").count == 2)
}

@Test func valuesOfThePhase3Types() throws {
    #expect(AnnotationPlan.legacy == AnnotationPlan(items: []))
    #expect(MusicPlan.legacy == MusicPlan(items: [], ducking: Ducking(enabled: true, amount: -12, attack: 0.3, release: 0.8)))
    #expect(Ducking.default == Ducking(enabled: true, amount: -12, attack: 0.3, release: 0.8))
    #expect(MarkerPlan.legacy == MarkerPlan(items: []))
    #expect(LoupeStyle.default == LoupeStyle(radius: 0.16, shape: .circle))
    #expect(LoupeStyle.radiusRange == 0.06...0.4)
    #expect(ClipContent.freezeDuration == 2_000_000_000)
    #expect(ClipContent.cardDuration == 3_000_000_000)
    #expect(ClipContent.durationRange == 100_000_000...60_000_000_000)
    #expect(GainRange.silence == -120)
    #expect(RGBA.annotationRed == RGBA(1, 69.0 / 255, 58.0 / 255, 1))
    // The defaults of §10 and of plan decision 3.
    let card = TitleCard(title: "Hola", style: .centered, background: .stage)
    #expect(card.subtitle == "" && card.textColor == RGBA(1, 1, 1, 1))
    let media = MediaClip(asset: DocumentV4Example.media, start: 0, end: 1)
    #expect(media.speed == 1 && media.volume == 0)
    let annotation = Annotation(id: "a-00000001", anchor: .whole, layer: 0, kind: .step(StepAnnotation()), rect: .unit)
    #expect(annotation.rotation == 0 && annotation.opacity == 1 && annotation.enter == .fade && annotation.exit == .fade)
    for preset in TextPreset.allCases {
        let text = TextAnnotation(string: "x", preset: preset)
        #expect(text.font == .system && text.weight == .semibold && text.size == 0.05 && text.align == .center, "\(preset)")
        #expect(text.color == RGBA(1, 1, 1, 1), "\(preset)")
        #expect(text.fill == TextAnnotation.defaultFill(for: preset), "\(preset)")
    }
    #expect(TextAnnotation.defaultFill(for: .label) == RGBA(0, 0, 0, 0.7))
    #expect(TextAnnotation.defaultFill(for: .lowerThird) == RGBA(0, 0, 0, 0.7))
    #expect(TextAnnotation.defaultFill(for: .plain) == nil)
    #expect(TextAnnotation.defaultFill(for: .title) == nil)
    #expect(TextAnnotation(string: "x", preset: .label, fill: nil).fill == nil)
    let arrow = ArrowAnnotation(from: NormalizedPoint(x: 0, y: 0), to: NormalizedPoint(x: 1, y: 1), head: .open)
    #expect(arrow.curve == 0 && arrow.color == .annotationRed && arrow.width == 0.006)
    let shape = ShapeAnnotation(shape: .rect)
    #expect(shape.stroke == .annotationRed && shape.width == 0.004 && shape.fill == nil)
    #expect(StepAnnotation().color == .annotationRed)
    let image = ImageAnnotation(asset: DocumentV4Example.image, fit: .fill)
    #expect(image.corner == 0 && !image.shadow)
    let clip = ClipAnnotation(asset: DocumentV4Example.video, start: 0, end: 1)
    #expect(clip.volume == 0 && !clip.muted && clip.corner == 0 && !clip.shadow)
    let piece = MusicItem(id: "mu-00000001", source: "library:music-1/calma", start: 0, end: 1)
    #expect(piece.offset == 0 && piece.gain == -14 && piece.fadeIn == 1_000_000_000 && piece.fadeOut == 2_000_000_000 && piece.loop)
    let marker = Marker(id: "m-00000001", take: "take-001", t: ns(1), origin: .added)
    #expect(marker.name == "" && !marker.hidden)
    // The new fields of the types of phases 1 and 2 default to their legacy values.
    #expect(TrackGain(gain: 1, muted: false).ranges.isEmpty)
    #expect(DefaultStyle.toma.zoomAuto.mode == .classic)
    let plain = EditDocument(
        documentVersion: 4, logSequence: 0, aspect: .landscape, frameRate: 60, sequence: [], screens: ScreenPlan(initial: [:], changes: []),
        style: DefaultStyle.toma.style, cursor: DefaultStyle.toma.cursor,
        zoom: ZoomPlan(show: true, auto: DefaultStyle.toma.zoomAuto, spring: DefaultStyle.toma.zoomSpring, motionBlur: 0, regions: [], suppressed: []),
        camera: CameraPlan(show: true, initial: [:], changes: []), audio: AudioPlan(limiter: false, tracks: [:]))
    #expect(plain.annotations == .legacy && plain.music == .legacy && plain.markers == .legacy)
    // The raw values are written in `edit.json`, so they never change.
    #expect(TitleCardStyle.allCases.map(\.rawValue) == ["centered", "leading", "large", "minimal"])
    #expect(ZoomMode.allCases.map(\.rawValue) == ["classic", "highlight", "dim", "loupe"])
    #expect(LoupeShape.allCases.map(\.rawValue) == ["circle", "roundedRect"])
    #expect(AnnotationEnter.allCases.map(\.rawValue) == ["none", "fade", "pop", "draw"])
    #expect(AnnotationExit.allCases.map(\.rawValue) == ["none", "fade"])
    #expect(TextPreset.allCases.map(\.rawValue) == ["plain", "label", "lowerThird", "title"])
    #expect(TextFont.allCases.map(\.rawValue) == ["system", "rounded", "serif", "mono"])
    #expect(TextWeight.allCases.map(\.rawValue) == ["regular", "semibold", "bold", "heavy"])
    #expect(TextAlign.allCases.map(\.rawValue) == ["leading", "center", "trailing"])
    #expect(ArrowHead.allCases.map(\.rawValue) == ["filled", "open", "none"])
    #expect(AnnotationShape.allCases.map(\.rawValue) == ["rect", "roundedRect", "ellipse"])
    #expect(ImageFit.allCases.map(\.rawValue) == ["fit", "fill"])
    #expect(MarkerOrigin.allCases.map(\.rawValue) == ["recorded", "added"])
}

@Test func flatShapesAreExact() throws {
    let white = RGBA(1, 1, 1, 1)
    let card = TitleCard(title: "T", style: .minimal, background: .stage)
    let cardJSON = #"{"background":{"type":"stage"},"style":"minimal","subtitle":"","textColor":[1,1,1,1],"title":"T"}"#
    let media = MediaClip(asset: "assets/x.mov", start: 1, end: 2)
    let mediaJSON = #"{"asset":"assets/x.mov","end":2,"speed":1,"start":1,"volume":0}"#
    let contents: [(ClipContent, String)] = [
        (.freeze(duration: 2_000_000_000), #"{"duration":2000000000,"type":"freeze"}"#),
        (.card(card, duration: 3_000_000_000), #"{"card":"# + cardJSON + #","duration":3000000000,"type":"card"}"#),
        (.media(media), #"{"media":"# + mediaJSON + #","type":"media"}"#),
    ]
    let backgrounds: [(TitleCardBackground, String)] = [
        (.stage, #"{"type":"stage"}"#), (.color(RGBA(0, 0.5, 1, 1)), #"{"color":[0,0.5,1,1],"type":"color"}"#),
        (.blurredFrame, #"{"type":"blurredFrame"}"#),
    ]
    let anchors: [(AnnotationAnchor, String)] = [
        (.content(take: "take-001", start: ns(5), end: ns(9)), #"{"end":9,"start":5,"take":"take-001","type":"content"}"#),
        (.output(start: 5, end: 9), #"{"end":9,"start":5,"type":"output"}"#), (.whole, #"{"type":"whole"}"#),
    ]
    let point = NormalizedPoint(x: 0.5, y: 0.25)
    let text = TextAnnotation(string: "s", preset: .title, font: .mono, weight: .heavy, size: 0.1, color: white, fill: RGBA(0, 0, 0, 1), align: .trailing)
    let textFields = #""align":"trailing","color":[1,1,1,1],"fill":[0,0,0,1],"font":"mono","preset":"title","size":0.1,"string":"s""#
    let kinds: [(AnnotationKind, String)] = [
        (.text(text), "{" + textFields + #","type":"text","weight":"heavy"}"#),
        (
            .arrow(ArrowAnnotation(from: point, to: point, curve: -1, color: white, width: 0.01, head: .none)),
            #"{"color":[1,1,1,1],"curve":-1,"from":{"x":0.5,"y":0.25},"head":"none","to":{"x":0.5,"y":0.25},"type":"arrow","width":0.01}"#
        ),
        (
            .shape(ShapeAnnotation(shape: .rect, stroke: white, width: 0.002, fill: white)),
            #"{"fill":[1,1,1,1],"shape":"rect","stroke":[1,1,1,1],"type":"shape","width":0.002}"#
        ),
        (
            .callout(CalloutAnnotation(text: text, target: point)),
            #"{"target":{"x":0.5,"y":0.25},"text":{"# + textFields + #","weight":"heavy"},"type":"callout"}"#
        ),
        (.step(StepAnnotation(color: white)), #"{"color":[1,1,1,1],"type":"step"}"#),
        (
            .image(ImageAnnotation(asset: "assets/x.png", fit: .fill, corner: 0.1, shadow: true)),
            #"{"asset":"assets/x.png","corner":0.1,"fit":"fill","shadow":true,"type":"image"}"#
        ),
        (
            .clip(ClipAnnotation(asset: "assets/x.mov", start: 1, end: 2, volume: -3, muted: true, corner: 0, shadow: false)),
            #"{"asset":"assets/x.mov","corner":0,"end":2,"muted":true,"shadow":false,"start":1,"type":"clip","volume":-3}"#
        ),
    ]
    func check<T: Codable & Equatable>(_ cases: [(T, String)]) throws {
        for (value, json) in cases {
            #expect(try compact(value) == json)
            #expect(try ProjectJSON.decoder().decode(T.self, from: Data(json.utf8)) == value, "\(json)")
        }
    }
    try check(contents)
    try check(backgrounds)
    try check(anchors)
    try check(kinds)
    try check([(LoupeStyle.default, #"{"radius":0.16,"shape":"circle"}"#)])
    try check([
        (
            GainRange(id: "g-00000001", take: "take-001", start: ns(1), end: ns(2), gain: -6),
            #"{"end":2,"gain":-6,"id":"g-00000001","start":1,"take":"take-001"}"#
        )
    ])
    try check([
        (
            Marker(id: "m-00000001", take: "take-001", t: ns(7), origin: .added),
            #"{"hidden":false,"id":"m-00000001","name":"","origin":"added","t":7,"take":"take-001"}"#
        )
    ])
    try check([
        (
            MusicPlan.legacy,
            #"{"ducking":{"amount":-12,"attack":0.3,"enabled":true,"release":0.8},"items":[]}"#
        )
    ])
    // A missing member of a case is no value.
    for json in [#"{"type":"freeze"}"#, #"{"duration":1,"type":"card"}"#, #"{"type":"media"}"#] {
        #expect(throws: DecodingError.self, "\(json)") { try ProjectJSON.decoder().decode(ClipContent.self, from: Data(json.utf8)) }
    }
    #expect(throws: DecodingError.self) { try ProjectJSON.decoder().decode(TitleCardBackground.self, from: Data(#"{"type":"color"}"#.utf8)) }
    for json in [#"{"end":1,"start":0,"type":"content"}"#, #"{"start":0,"type":"output"}"#] {
        #expect(throws: DecodingError.self, "\(json)") { try ProjectJSON.decoder().decode(AnnotationAnchor.self, from: Data(json.utf8)) }
    }
    #expect(throws: DecodingError.self) { try ProjectJSON.decoder().decode(AnnotationKind.self, from: Data(#"{"type":"step"}"#.utf8)) }
}

@Test func unknownPhase3CaseIsInvalidNotNewer() throws {
    let base = try parsed(DocumentV4Example.canonical)
    func item(_ collection: String, _ index: Int, _ change: @escaping (inout JSONValue) -> Void) -> (inout JSONValue) -> Void {
        { document in
            guard case var .array(elements)? = document.at(collection) else { return }
            change(&elements[index])
            let components = (try? JSONPointer(collection).components) ?? []
            if components.count == 1 {
                document[components[0]] = .array(elements)
            } else {
                document[components[0]]?[components[1]] = .array(elements)
            }
        }
    }
    let cases: [(String, (inout JSONValue) -> Void)] = [
        ("zoom mode", { $0["zoom"]?["auto"]?["mode"] = .string("spin") }),
        ("region mode", item("/zoom/regions", 1) { $0["mode"] = .string("spin") }),
        ("loupe shape", item("/zoom/regions", 1) { $0["loupe"]?["shape"] = .string("star") }),
        ("content", item("/sequence", 2) { $0["content"]?["type"] = .string("still") }),
        ("card style", item("/sequence", 3) { $0["content"]?["card"]?["style"] = .string("wide") }),
        ("card background", item("/sequence", 3) { $0["content"]?["card"]?["background"]?["type"] = .string("video") }),
        ("audioShift", item("/sequence", 1) { $0["audioShift"] = .number(0.5) }),
        ("audioShift gone", item("/sequence", 1) { $0["audioShift"] = nil }),
        ("annotation kind", item("/annotations/items", 4) { $0["kind"]?["type"] = .string("sticker") }),
        ("anchor", item("/annotations/items", 0) { $0["anchor"]?["type"] = .string("chapter") }),
        ("preset", item("/annotations/items", 0) { $0["kind"]?["preset"] = .string("banner") }),
        ("font", item("/annotations/items", 0) { $0["kind"]?["font"] = .string("comic") }),
        ("weight", item("/annotations/items", 0) { $0["kind"]?["weight"] = .string("thin") }),
        ("align", item("/annotations/items", 0) { $0["kind"]?["align"] = .string("justified") }),
        ("head", item("/annotations/items", 1) { $0["kind"]?["head"] = .string("diamond") }),
        ("shape", item("/annotations/items", 2) { $0["kind"]?["shape"] = .string("star") }),
        ("fit", item("/annotations/items", 5) { $0["kind"]?["fit"] = .string("stretch") }),
        ("enter", item("/annotations/items", 1) { $0["enter"] = .string("slide") }),
        ("exit", item("/annotations/items", 1) { $0["exit"] = .string("pop") }),
        ("marker origin", item("/markers/items", 0) { $0["origin"] = .string("imported") }),
        ("ducking", { $0["music"]?["ducking"]?["enabled"] = .string("yes") }),
        ("ranges gone", { $0["audio"]?["tracks"]?["take-001/mic"]?["ranges"] = nil }),
        ("annotations", { $0["annotations"] = nil }),
        ("music", { $0["music"] = nil }),
        ("markers", { $0["markers"] = nil }),
    ]
    for (name, change) in cases {
        var text = base
        change(&text)
        #expect(text != base, "\(name)")
        // A `DecodingError`, never `EditDocumentError.newerVersion`: the document is damaged, not newer.
        #expect(throws: DecodingError.self, "\(name)") { try EditDocument.decode(json: text) }
        #expect(throws: DecodingError.self, "\(name)") { try EditDocument.decode(Data(compact(text).utf8)) }
        let line = #"{"app":{"name":"Toma","version":"0.5.0"},"document":"# + (try compact(text)) + #","seq":1,"type":"create"}"#
        #expect(throws: DecodingError.self, "\(name)") { try EditLogEntry(jsonLine: line) }
    }
}

@Test func version6IsRefused() throws {
    // Of version 6 since phases 4 and 5, whose document is of version 5.
    #expect(throws: EditDocumentError.newerVersion(6)) {
        try EditDocument.decode(Data(#"{"documentVersion":6,"aspect":"4:3"}"#.utf8))
    }
    let newer = DocumentV4Example.canonical.replacingOccurrences(of: "\"documentVersion\" : 4", with: "\"documentVersion\" : 6")
    #expect(newer != DocumentV4Example.canonical)
    #expect(throws: EditDocumentError.newerVersion(6)) { try EditDocument.decode(Data(newer.utf8)) }
    #expect(throws: EditDocumentError.newerVersion(6)) { try EditDocument.decode(json: parsed(newer)) }
    // Inside the `create` of a log too, and a `migrate` to 6.
    let line = #"{"app":{"name":"Toma","version":"0.7.0"},"document":"# + (try compact(parsed(newer))) + #","seq":1,"type":"create"}"#
    #expect(throws: EditDocumentError.newerVersion(6)) { try EditLogEntry(jsonLine: line) }
    try withTemporaryDirectory { dir in
        let url = dir.appending(path: "edit-log.jsonl")
        try Data((line + "\n").utf8).write(to: url)
        #expect(throws: EditDocumentError.newerVersion(6)) { try EditLogReader.read(url) }
        let create = EditLogEntry.create(seq: 1, document: DocumentV4Example.document, app: AppInfo(name: "Toma", version: "0.5.0"))
        let migrate = try EditLogEntry.migrate(seq: 2, from: 5, to: 6).jsonLine()
        try Data((try create.jsonLine() + "\n" + migrate + "\n").utf8).write(to: url)
        #expect(throws: EditDocumentError.newerVersion(6)) { try EditLogReader.read(url) }
        // A `migrate` to 4 is one this app follows.
        let v3 = EditLogEntry.create(seq: 1, document: DocumentV3Example.document, app: AppInfo(name: "Toma", version: "0.4.0"))
        try Data((try v3.jsonLine(writingDocumentAt: 3) + "\n" + EditLogEntry.migrate(seq: 2, from: 3, to: 4).jsonLine() + "\n").utf8)
            .write(to: url)
        #expect(try EditLogReader.read(url).createVersion == 3)
    }
}

// MARK: - Undoing the migration, and what commutes with it

@Test func revertedWalksDownFrom4() throws {
    let v1 = try parsed(DocumentV1Example.canonical)
    let v2 = try parsed(DesignExample.canonical)
    let v3 = try parsed(DocumentV3Example.canonical)
    let v4 = try DocumentMigration.migrate(v3, from: 3)
    #expect(DocumentMigration.reverted(v4, to: 3) == v3)
    #expect(DocumentMigration.reverted(v4, to: 4) == v4)
    let fromV1 = try DocumentMigration.migrate(DocumentMigration.migrate(DocumentMigration.migrate(v1, from: 1), from: 2), from: 3)
    #expect(DocumentMigration.reverted(fromV1, to: 1) == v1)
    #expect(DocumentMigration.reverted(fromV1, to: 2) == v2)
    #expect(DocumentMigration.reverted(try JSONValue(encoding: DesignExample.document), to: 1) == v1)
    #expect(DocumentMigration.oldestVersion(holding: DesignExample.document) == 1)
    #expect(DocumentMigration.oldestVersion(holding: DocumentV3Example.document) == 3)
    // Never forward, nor from a version this app has no migration to.
    #expect(DocumentMigration.reverted(v3, to: 4) == nil)
    var v5 = v4
    v5["documentVersion"] = .integer(5)
    #expect(DocumentMigration.reverted(v5, to: 4) == nil)
    #expect(DocumentMigration.reverted(v5, to: 5) == v5)

    // A document that uses what version 4 adds has no version 3, nor 2, nor 1.
    let freeze = try JSONValue(encoding: ClipContent.freeze(duration: 2_000_000_000))
    let uses: [(String, (inout JSONValue) -> Void)] = [
        ("a marker", { $0["markers"]?["items"] = .array([.object(["id": .string("m-00000001")])]) }),
        ("an annotation", { $0["annotations"]?["items"] = .array([.object(["id": .string("a-00000001")])]) }),
        ("music", { $0["music"]?["items"] = .array([.object(["id": .string("mu-00000001")])]) }),
        ("no ducking", { $0["music"]?["ducking"]?["enabled"] = .bool(false) }),
        ("a clip with content", { $0["sequence"]?[1]?["content"] = freeze }),
        ("an audio shift of 40", { $0["sequence"]?[1]?["audioShift"] = .integer(40) }),
        ("a region with a mode", { $0["zoom"]?["regions"]?[0]?["mode"] = .string("classic") }),
        ("a region with a loupe", { $0["zoom"]?["regions"]?[1]?["loupe"] = .object(["radius": .number(0.16), "shape": .string("circle")]) }),
        ("dimming", { $0["zoom"]?["auto"]?["mode"] = .string("dim") }),
        ("a range", { $0["audio"]?["tracks"]?["take-001/mic"]?["ranges"] = .array([.object(["id": .string("g-00000001")])]) }),
        ("a missing place", { $0["markers"] = nil }),
        ("a missing shift", { $0["sequence"]?[0]?["audioShift"] = nil }),
    ]
    for (name, use) in uses {
        var document = v4
        use(&document)
        #expect(document != v4, "\(name)")
        #expect(DocumentMigration.reverted(document, to: 3) == nil, "\(name)")
        #expect(DocumentMigration.reverted(document, to: 2) == nil, "\(name)")
        #expect(DocumentMigration.reverted(document, to: 1) == nil, "\(name)")
        #expect(DocumentMigration.reverted(document, to: 4) == document, "\(name)")
    }
}

@Test func touchesAddedFieldsFrom3() throws {
    let v3 = try parsed(DocumentV3Example.canonical)
    func whole(_ pointer: String, _ change: (inout JSONValue) -> Void) throws -> EditChange {
        let before = try #require(v3.at(pointer))
        var after = before
        change(&after)
        return .set(path: try JSONPointer(pointer), before: before, after: after)
    }
    let clip = try #require(v3.at("/sequence/0"))
    let region = try #require(v3.at("/zoom/regions/0"))
    let marker = try JSONValue(encoding: Marker(id: "m-00000001", take: "take-001", t: ns(1), origin: .added))
    let cases: [(EditChange, Bool)] = [
        (.set(path: try pointer(""), before: v3, after: v3), true),
        (.set(path: try pointer("/documentVersion"), before: .integer(3), after: .integer(4)), true),
        (.set(path: try pointer("/annotations"), before: .null, after: .object(["items": .array([])])), true),
        (.set(path: try pointer("/music/ducking/amount"), before: .integer(-12), after: .integer(-6)), true),
        (.insert(collection: try pointer("/markers/items"), index: 0, value: marker), true),
        (.set(path: try pointer("/sequence/0/audioShift"), before: .null, after: .integer(5)), true),
        (.set(path: try pointer("/zoom/auto/mode"), before: .null, after: .string("dim")), true),
        (.set(path: try pointer("/audio/tracks/take-001~1mic/ranges"), before: .null, after: .array([])), true),
        // Carried: the clip and the track with their place at its frozen value.
        (.insert(collection: try pointer("/sequence"), index: 2, value: clip), false),
        (.replace(collection: try pointer("/sequence"), id: "c-00a1b2c3", before: clip, after: clip), false),
        (try whole("/zoom/auto") { $0["depth"] = .number(3) }, false),
        (try whole("/audio/tracks/take-001~1mic") { $0["gain"] = .number(0.5) }, false),
        (try whole("/audio/tracks") { $0["take-001/mic"]?["muted"] = .bool(true) }, false),
        (try whole("/sequence") { $0[0]?["speed"] = .integer(2) }, false),
        (.insert(collection: try pointer("/zoom/regions"), index: 0, value: region), false),
        (.set(path: try pointer("/zoom/auto/depth"), before: .integer(2), after: .integer(3)), false),
        (.set(path: try pointer("/style/padding"), before: .number(0.08), after: .number(0.1)), false),
        (.set(path: try pointer("/sequence/0/end"), before: .integer(81_276_901_234_567), after: .integer(81_276_000_000_000)), false),
    ]
    for (change, touches) in cases {
        #expect(DocumentMigration.touchesAddedFields(change, from: 3) == touches, "\(change)")
    }
    // What is carried writes the places at their frozen values, so it applies to the migrated document as to the v3.
    let v4 = try DocumentMigration.migrate(v3, from: 3)
    for (change, touches) in cases where !touches {
        let carried = try #require(DocumentMigration.carried(change, from: 3), "\(change)")
        let before = try DocumentMigration.migrate(v3.applying([change]), from: 3)
        #expect(try v4.applying([carried]) == before, "\(change)")
    }
    let carriedClip = try #require(DocumentMigration.carried(.insert(collection: try pointer("/sequence"), index: 2, value: clip), from: 3))
    guard case let .insert(_, _, value) = carriedClip else { return }
    #expect(value["audioShift"] == .integer(0))
    let track = try whole("/audio/tracks/take-001~1mic") { $0["gain"] = .number(0.5) }
    guard case let .set(_, before, after)? = DocumentMigration.carried(track, from: 3) else { return }
    #expect(before["ranges"] == .array([]) && after["ranges"] == .array([]))
    let auto = try whole("/zoom/auto") { $0["depth"] = .number(3) }
    guard case let .set(_, _, autoAfter)? = DocumentMigration.carried(auto, from: 3) else { return }
    #expect(autoAfter["mode"] == .string("classic"))
    // A whole value that has the place already with another value does not commute.
    var shifted = clip
    shifted["audioShift"] = .integer(7)
    #expect(DocumentMigration.touchesAddedFields(.insert(collection: try pointer("/sequence"), index: 2, value: shifted), from: 3))
}

@Test func savedStylesWithoutModeReadClassic() throws {
    // `default-style.json` and a `.tomastyle` of phase 2 hold the automatic zoom's settings without `mode`: `classic`.
    var saved = try JSONValue(encoding: DefaultStyle.toma)
    #expect(saved["zoomAuto"]?["mode"] == .string("classic"))
    saved["zoomAuto"]?["mode"] = nil
    #expect(try ProjectJSON.decoder().decode(DefaultStyle.self, from: Data(compact(saved).utf8)) == DefaultStyle.toma)
    var dimming = DefaultStyle.toma
    dimming.zoomAuto.mode = .dim
    #expect(try ProjectJSON.decoder().decode(DefaultStyle.self, from: ProjectJSON.compactEncoder().encode(dimming)) == dimming)
    // In a document it is always written, and a change that takes it away is refused.
    let document = DesignExample.document
    let away = EditChange.set(path: try pointer("/zoom/auto/mode"), before: .string("classic"), after: .null)
    #expect(throws: EditChangeError.invalidDocument("/zoom/auto/mode")) { try document.applying([away]) }
}

@Test func phase3CollectionsAreArraysOfTheDocument() throws {
    #expect(EditCollection.annotations.rawValue == "/annotations/items")
    #expect(EditCollection.music.rawValue == "/music/items")
    #expect(EditCollection.markers.rawValue == "/markers/items")
    let ranges = EditCollection.gainRanges(track: "take-001/mic")
    #expect(ranges.rawValue == "/audio/tracks/take-001~1mic/ranges")
    #expect(ranges.pointer.components == ["audio", "tracks", "take-001/mic", "ranges"])
    #expect(EditCollection(rawValue: ranges.rawValue) == ranges)
    #expect(EditCollection(rawValue: "/sequence") == .sequence)
    // Inserted, replaced and removed by id, from the legacy document to the example's and back.
    var document = DesignExample.document
    let example = DocumentV4Example.document
    let collections: [(EditCollection, [JSONValue])] = [
        (.annotations, try example.annotations.items.map { try JSONValue(encoding: $0) }),
        (.music, try example.music.items.map { try JSONValue(encoding: $0) }),
        (.markers, try example.markers.items.map { try JSONValue(encoding: $0) }),
        (ranges, try (example.audio.tracks["take-001/mic"]?.ranges ?? []).map { try JSONValue(encoding: $0) }),
    ]
    for (collection, items) in collections {
        for (index, item) in items.enumerated() {
            document = try document.applying([document.insertChange(collection, at: index, item)])
        }
    }
    #expect(document.annotations == example.annotations)
    #expect(document.music.items == example.music.items)
    #expect(document.markers == example.markers)
    #expect(document.audio.tracks["take-001/mic"]?.ranges == example.audio.tracks["take-001/mic"]?.ranges)
    var renamed = example.markers.items[0]
    renamed.name = "Final"
    let replace = try #require(document.replaceChange(.markers, id: renamed.id, with: renamed))
    #expect(try document.applying([replace]).markers.items == [renamed])
    let remove = try #require(document.removeChange(ranges, at: 0))
    #expect(try document.applying([remove]).audio.tracks["take-001/mic"]?.ranges == [])
    // A track that is not there has no collection.
    #expect(throws: EditChangeError.noSuchPath("/audio/tracks/take-002~1mic/ranges")) {
        try document.applying([document.insertChange(.gainRanges(track: "take-002/mic"), at: 0, example.audio.tracks["take-001/mic"]?.ranges[0])])
    }
    // The applying from the JSON gives the same.
    let json = try #require(DesignExample.document.heldJSON())
    let insert = DesignExample.document.insertChange(.markers, at: 0, example.markers.items[0])
    let fast = try DesignExample.document.applying([insert], json: json)
    #expect(fast.document == (try DesignExample.document.applying([insert])))
    #expect(fast.json == (try JSONValue(encoding: fast.document)))
}
