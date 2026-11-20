// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Export
import ProjectFormat

/// The JSON Schema of the API's commands (draft 2020-12, plan 4b decision 16): the source of
/// `docs/format/schema/edit-command.schema.json` (written from it, and compared by a test) and of the input schemas of
/// the MCP server's tools. Each command is a `$defs` entry named as the command, with examples; nothing says
/// `additionalProperties: false` (a reader ignores keys it does not know), though `ProjectCommand` refuses them.
public enum CommandSchema {
    /// The schema with a `$defs` entry per command and a `oneOf` of `$ref`s to them.
    public static var document: JSONValue {
        var root = header
        root["oneOf"] = definitions.map { ["$ref": "#/$defs/\($0.name)"] }
        root["$defs"] = Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0.schema) })
        return json(root)
    }

    /// The same without `$ref`, each command's schema in the `oneOf`: for the MCP server, whose clients may not follow
    /// references.
    public static var inline: JSONValue {
        var root = header
        root["oneOf"] = definitions.map(\.schema)
        return json(root)
    }

    // MARK: - Private

    private static var header: [String: Any] {
        [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "title": "Toma edit command",
            "description": "One edit of a Toma project, as the toma command, its MCP server and the app's control socket take it. "
                + "Times are seconds of the output as the project plays now. Each command is one undo step, the same step "
                + "the app's gesture makes.",
            "type": "object",
            "properties": ["command": ["type": "string", "enum": ProjectCommand.names]],
            "required": ["command"],
        ]
    }

    private struct Definition {
        var name: String
        var schema: [String: Any]
    }

    private static func command(
        _ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = [],
        examples: [[String: Any]]
    ) -> Definition {
        var all = properties
        all["command"] = ["const": name]
        let schema: [String: Any] = [
            "type": "object",
            "description": description,
            "properties": all,
            "required": ["command"] + required,
            "examples": examples.map { example in
                var object = example
                object["command"] = name
                return object
            },
        ]
        return Definition(name: name, schema: schema)
    }

    private static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> [String: Any] {
        var object: [String: Any] = ["type": "number", "description": description]
        if let minimum { object["minimum"] = minimum }
        if let maximum { object["maximum"] = maximum }
        return object
    }

    /// A string; with `limit`, one the command holds to that many characters as a person counts them (grapheme
    /// clusters, `String.count`), cutting a longer one. The limit goes in the description, never as `maxLength`, which
    /// counts code points: the format promises characters (`docs/format/README.md`, "Estabilidad").
    private static func string(_ description: String, limit: Int? = nil) -> [String: Any] {
        var text = description
        if let limit { text += " Up to \(limit) characters (grapheme clusters); a longer one is cut." }
        return ["type": "string", "description": text]
    }

    private static func choice(_ description: String, _ values: [String]) -> [String: Any] {
        ["type": "string", "description": description, "enum": values]
    }

    private static func boolean(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    private static var seconds: [String: Any] { number("Seconds of the output, from 0 to its length.", minimum: 0) }
    private static var fraction: [String: Any] { number("A fraction from 0 to 1.", minimum: 0, maximum: 1) }

    private static var rgba: [String: Any] {
        [
            "type": "array", "description": "A colour, sRGB values from 0 to 1: [r, g, b, a].",
            "items": ["type": "number", "minimum": 0.0, "maximum": 1.0] as [String: Any], "minItems": 4, "maxItems": 4,
        ]
    }

    private static var background: [String: Any] {
        [
            "type": "object",
            "description": "The document's Background: a gradient {start, end, angle}, a color, a wallpaper of Toma's "
                + "(\"aurora-1\"…), an image (its file assets/<name> of the project, or the absolute path of one to bring in) "
                + "or the desktop picture.",
            "properties": [
                "type": choice("What it is.", ["gradient", "color", "wallpaper", "image", "desktop"]),
                "start": rgba, "end": rgba, "color": rgba,
                "angle": number("Degrees, as in CSS: 0 goes up, 90 to the right."),
                "wallpaper": string("The versioned id of a wallpaper of Toma's, such as aurora-1."),
                "file": string("assets/<name> of the project, or the absolute path of an image (PNG, JPEG, HEIC, TIFF, GIF, PDF)."),
            ] as [String: Any],
            "required": ["type"],
        ]
    }

    private static var definitions: [Definition] {
        [
            command(
                "cut", "Deletes the output from `from` to `to`: the sequence closes the gap.",
                ["from": seconds, "to": seconds], required: ["from", "to"], examples: [["from": 12.5, "to": 15.0]]),
            command("trimStart", "Deletes the output from its start to `to`.", ["to": seconds], required: ["to"], examples: [["to": 1.5]]),
            command("trimEnd", "Deletes the output from `from` to its end.", ["from": seconds], required: ["from"], examples: [["from": 58.0]]),
            command(
                "setSpeed", "Plays the output from `from` to `to` at `speed` (split at both edges first).",
                [
                    "from": seconds, "to": seconds,
                    "speed": number(
                        "How many times as fast: 0.25 to 16. Up to 4 the sound speeds up without changing pitch.", minimum: 0.25,
                        maximum: 16),
                ], required: ["from", "to", "speed"], examples: [["from": 20.0, "to": 30.0, "speed": 2.0]]),
            command("removeFillers", "Cuts the filler words of the transcript (\"um\", \"eh\"…).", examples: [[:]]),
            command(
                "shortenPauses", "Shortens every pause between words of the transcript longer than `longerThan` seconds.",
                ["longerThan": number("Seconds, above 0; a pause keeps 0.4 s.", minimum: 0)], required: ["longerThan"],
                examples: [["longerThan": 1.5]]),
            command(
                "addZoom", "A zoom block of the user's over the output from `from` to `to`.",
                [
                    "from": seconds, "to": seconds,
                    "depth": number("How far it zooms, 1.25 to 4; without it, the project's depth.", minimum: 1.25, maximum: 4),
                    "focus": [
                        "type": ["string", "object"],
                        "description": "\"follow\" (the cursor) or a point of the screen {\"x\", \"y\"}, fractions from 0 to 1.",
                        "properties": ["x": fraction, "y": fraction],
                    ] as [String: Any],
                ], required: ["from", "to"],
                examples: [
                    ["from": 4.0, "to": 8.0],
                    ["from": 10.0, "to": 13.0, "depth": 2.0, "focus": ["x": 0.25, "y": 0.4]],
                    ["from": 20.0, "to": 23.0, "focus": "follow"],
                ]),
            command(
                "removeZoom", "Deletes a zoom block, by the id the project report gives.", ["id": string("The block's id.")],
                required: ["id"], examples: [["id": "z-1a2b3c4d"]]),
            command(
                "setAutoZoom", "Turns the automatic zoom on or off, and whether it follows the keyboard's focus; it plans again.",
                ["enabled": boolean("Whether the automatic zoom is on."), "followsFocus": boolean("Whether it follows the focus.")],
                required: ["enabled"], examples: [["enabled": true, "followsFocus": true]]),
            command(
                "addMarker", "A marker at `at`; one with a name is a chapter.",
                ["at": seconds, "name": string("Its name; \"\" for none.", limit: MarkerCommands.maximumNameLength)],
                required: ["at", "name"], examples: [["at": 42.0, "name": "Setup"]]),
            command(
                "renameMarker", "Names a marker, by the id the project report gives.",
                ["id": string("The marker's id."), "name": string("Its name; \"\" for none.", limit: MarkerCommands.maximumNameLength)],
                required: ["id", "name"], examples: [["id": "m-1a2b3c4d", "name": "Demo"]]),
            command(
                "removeMarker", "Deletes a marker (a recorded one is hidden).", ["id": string("The marker's id.")],
                required: ["id"], examples: [["id": "m-1a2b3c4d"]]),
            command(
                "setAspect", "The shape of the output.", ["aspect": choice("The aspect ratio.", Aspect.allCases.map(\.rawValue))],
                required: ["aspect"], examples: [["aspect": "9:16"]]),
            command(
                "setBackground", "What is behind the screen.", ["background": background], required: ["background"],
                examples: [
                    ["background": ["type": "wallpaper", "wallpaper": "aurora-1"]],
                    ["background": ["type": "color", "color": [0.1, 0.1, 0.12, 1.0]] as [String: Any]],
                ]),
            command(
                "applyStyle", "Applies a named style: \"toma\" for Toma's, or a style of the app's library by its id.",
                ["id": string("\"toma\", or the 8 hex digits of a saved style.")], required: ["id"], examples: [["id": "toma"]]),
            command(
                "setCameraLayout", "The project's camera layout, and a split's side.",
                [
                    "layout": choice("The layout.", LayoutKind.allCases.map(\.rawValue)),
                    "side": choice("Where the camera goes in a split: start (left or above) or end.", CameraSide.all.map(\.rawValue)),
                ], required: ["layout"], examples: [["layout": "split", "side": "start"], ["layout": "bubble"]]),
            command(
                "addTitleCard", "A title card at the start, at the end, or at a time of the output.",
                [
                    "at": ["type": ["string", "number"], "description": "\"start\", \"end\", or seconds of the output."] as [String: Any],
                    "title": string("Its title."), "subtitle": string("Its subtitle."),
                ], required: ["at", "title"],
                examples: [["at": "start", "title": "Release notes", "subtitle": "November"], ["at": 30.0, "title": "Part two"]]),
            command(
                "addText", "A text over the video from `from` to `to`, centred at `x`, `y` (fractions of the frame).",
                ["from": seconds, "to": seconds, "text": string("What it says."), "x": fraction, "y": fraction],
                required: ["from", "to", "text", "x", "y"],
                examples: [["from": 2.0, "to": 6.0, "text": "Click Export", "x": 0.5, "y": 0.8]]),
            command(
                "addMusic", "A theme of Toma's music library over the video from its start.",
                [
                    "theme": choice("The theme.", MusicThemes.ids),
                    "volume": number("In dB, -120 to 6; without it, -14.", minimum: MusicCommands.gains.lowerBound, maximum: 6),
                ], required: ["theme"], examples: [["theme": "calm", "volume": -18.0]]),
            command("removeMusic", "Takes out all the music.", examples: [[:]]),
            command(
                "setTitle", "The project's title.", ["title": string("\"\" takes it away.", limit: ProjectInfo.titleLimit)],
                required: ["title"], examples: [["title": "Release notes, November"]]),
            command(
                "setSummary", "The project's summary.",
                ["summary": string("\"\" takes it away.", limit: ProjectInfo.summaryLimit)], required: ["summary"],
                examples: [["summary": "What changed in the export sheet."]]),
            command(
                "transcribe", "Transcribes the takes on this Mac (never downloads a model).",
                [
                    "language": string("BCP 47 (es-AR, en-US); without it, the system's."),
                    "replace": boolean("Replace a transcript with corrections, losing them."),
                ], examples: [["language": "en-US"], ["language": "es-AR", "replace": true]]),
        ]
    }

    /// `value`, built of strings, numbers, booleans, arrays and dictionaries, as JSON.
    private static func json(_ value: Any) -> JSONValue {
        switch value {
        case let value as JSONValue: value
        case let value as String: .string(value)
        case let value as Bool: .bool(value)
        case let value as Int: .integer(Int64(value))
        case let value as Double: .number(value)
        case let value as [Any]: .array(value.map(json))
        case let value as [String: Any]: .object(value.mapValues(json))
        default: .null
        }
    }
}
