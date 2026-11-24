// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Render

/// Where a zoom block looks: at the cursor (`"follow"`), or at a point of the screen in fractions from 0 to 1
/// (`{"x": 0.3, "y": 0.6}`).
public enum CommandFocus: Codable, Equatable, Sendable {
    case follow
    case fixed(x: Double, y: Double)

    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        do throws(APIError) { self = try Self(json: value, command: "addZoom") } catch { throw error.decodingError(decoder) }
    }

    public func encode(to encoder: any Encoder) throws { try json.encode(to: encoder) }

    init(json: JSONValue, command: String) throws(APIError) {
        switch json {
        case .string("follow"):
            self = .follow
        case let .object(object):
            let fields = try CommandFields(command, object, keys: ["x", "y"], key: "focus")
            self = .fixed(x: try fields.number("x"), y: try fields.number("y"))
        default:
            throw APIError(.invalidCommand, "\(command): focus is \"follow\" or {\"x\", \"y\"}")
        }
    }

    var json: JSONValue {
        switch self {
        case .follow: .string("follow")
        case let .fixed(x, y): .object(["x": .number(x), "y": .number(y)])
        }
    }
}

/// Where a title card goes: before the first clip (`"start"`), after the last (`"end"`), or at an output time in seconds.
public enum CommandPlace: Codable, Equatable, Sendable {
    case start, end
    case at(Double)

    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        do throws(APIError) { self = try Self(json: value, command: "addTitleCard") } catch { throw error.decodingError(decoder) }
    }

    public func encode(to encoder: any Encoder) throws { try json.encode(to: encoder) }

    init(json: JSONValue, command: String) throws(APIError) {
        switch json {
        case .string("start"): self = .start
        case .string("end"): self = .end
        default:
            guard let seconds = json.double else {
                throw APIError(.invalidCommand, "\(command): at is \"start\", \"end\" or a time in seconds")
            }
            self = .at(seconds)
        }
    }

    var json: JSONValue {
        switch self {
        case .start: .string("start")
        case .end: .string("end")
        case let .at(seconds): .number(seconds)
        }
    }
}

/// One edit of the project API (fases 4 y 5 design §6.2), as JSON `{"command": "<name>", …}`: each one is the step of
/// the `*Commands` the app's gesture makes (`CommandSteps`). Times are seconds of the output, as the project plays now.
/// Decoding is strict (plan 4b decision 3): a command or a key it does not know is `invalidCommand`, naming it.
public enum ProjectCommand: Codable, Equatable, Sendable {
    case cut(from: Double, to: Double), trimStart(to: Double), trimEnd(from: Double)
    case setSpeed(from: Double, to: Double, speed: Double), removeFillers, shortenPauses(longerThan: Double)
    case addZoom(from: Double, to: Double, depth: Double?, focus: CommandFocus?), removeZoom(id: String)
    case setAutoZoom(enabled: Bool, followsFocus: Bool?)
    case addMarker(at: Double, name: String), renameMarker(id: String, name: String), removeMarker(id: String)
    case setAspect(Aspect), setBackground(Background), applyStyle(id: String)
    case setCameraLayout(LayoutKind, side: CameraSide?)
    case addTitleCard(at: CommandPlace, title: String, subtitle: String?)
    case addText(from: Double, to: Double, text: String, x: Double, y: Double)
    case addMusic(theme: String, volume: Double?), removeMusic
    case setTitle(String), setSummary(String)
    case transcribe(language: String?, replace: Bool)

    /// Every command's name, in the order of the cases: the `command` of its JSON.
    public static let names = [
        "cut", "trimStart", "trimEnd", "setSpeed", "removeFillers", "shortenPauses", "addZoom", "removeZoom",
        "setAutoZoom", "addMarker", "renameMarker", "removeMarker", "setAspect", "setBackground", "applyStyle",
        "setCameraLayout", "addTitleCard", "addText", "addMusic", "removeMusic", "setTitle", "setSummary", "transcribe",
    ]

    /// The `command` of its JSON.
    public var name: String {
        switch self {
        case .cut: "cut"
        case .trimStart: "trimStart"
        case .trimEnd: "trimEnd"
        case .setSpeed: "setSpeed"
        case .removeFillers: "removeFillers"
        case .shortenPauses: "shortenPauses"
        case .addZoom: "addZoom"
        case .removeZoom: "removeZoom"
        case .setAutoZoom: "setAutoZoom"
        case .addMarker: "addMarker"
        case .renameMarker: "renameMarker"
        case .removeMarker: "removeMarker"
        case .setAspect: "setAspect"
        case .setBackground: "setBackground"
        case .applyStyle: "applyStyle"
        case .setCameraLayout: "setCameraLayout"
        case .addTitleCard: "addTitleCard"
        case .addText: "addText"
        case .addMusic: "addMusic"
        case .removeMusic: "removeMusic"
        case .setTitle: "setTitle"
        case .setSummary: "setSummary"
        case .transcribe: "transcribe"
        }
    }

    /// The command `json` says: an object with `command` and its keys, nothing else.
    public init(json: JSONValue) throws(APIError) {
        guard case let .object(object) = json else { throw APIError(.invalidCommand, "a command is a JSON object") }
        guard let value = object["command"] else { throw APIError(.invalidCommand, "a command needs the key “command”") }
        guard case let .string(name) = value else { throw APIError(.invalidCommand, "“command” is the name of a command") }
        func fields(_ keys: Set<String>) throws(APIError) -> CommandFields { try CommandFields(name, object, keys: keys) }
        switch name {
        case "cut":
            let f = try fields(["from", "to"])
            self = .cut(from: try f.number("from"), to: try f.number("to"))
        case "trimStart":
            self = .trimStart(to: try fields(["to"]).number("to"))
        case "trimEnd":
            self = .trimEnd(from: try fields(["from"]).number("from"))
        case "setSpeed":
            let f = try fields(["from", "to", "speed"])
            self = .setSpeed(from: try f.number("from"), to: try f.number("to"), speed: try f.number("speed"))
        case "removeFillers":
            _ = try fields([])
            self = .removeFillers
        case "shortenPauses":
            self = .shortenPauses(longerThan: try fields(["longerThan"]).number("longerThan"))
        case "addZoom":
            let f = try fields(["from", "to", "depth", "focus"])
            var focus: CommandFocus?
            if let value = f.value("focus") { focus = try CommandFocus(json: value, command: name) }
            self = .addZoom(from: try f.number("from"), to: try f.number("to"), depth: try f.optionalNumber("depth"), focus: focus)
        case "removeZoom":
            self = .removeZoom(id: try fields(["id"]).string("id"))
        case "setAutoZoom":
            let f = try fields(["enabled", "followsFocus"])
            self = .setAutoZoom(enabled: try f.bool("enabled"), followsFocus: try f.optionalBool("followsFocus"))
        case "addMarker":
            let f = try fields(["at", "name"])
            self = .addMarker(at: try f.number("at"), name: try f.string("name"))
        case "renameMarker":
            let f = try fields(["id", "name"])
            self = .renameMarker(id: try f.string("id"), name: try f.string("name"))
        case "removeMarker":
            self = .removeMarker(id: try fields(["id"]).string("id"))
        case "setAspect":
            self = .setAspect(try fields(["aspect"]).raw("aspect", Aspect.allCases))
        case "setBackground":
            let f = try fields(["background"])
            guard let value = f.value("background") else { throw f.missing("background") }
            self = .setBackground(try Self.background(value))
        case "applyStyle":
            self = .applyStyle(id: try fields(["id"]).string("id"))
        case "setCameraLayout":
            let f = try fields(["layout", "side"])
            self = .setCameraLayout(try f.raw("layout", LayoutKind.allCases), side: try f.optionalRaw("side", CameraSide.all))
        case "addTitleCard":
            let f = try fields(["at", "title", "subtitle"])
            guard let at = f.value("at") else { throw f.missing("at") }
            self = .addTitleCard(
                at: try CommandPlace(json: at, command: name), title: try f.string("title"), subtitle: try f.optionalString("subtitle"))
        case "addText":
            let f = try fields(["from", "to", "text", "x", "y"])
            self = .addText(
                from: try f.number("from"), to: try f.number("to"), text: try f.string("text"), x: try f.number("x"),
                y: try f.number("y"))
        case "addMusic":
            let f = try fields(["theme", "volume"])
            self = .addMusic(theme: try f.string("theme"), volume: try f.optionalNumber("volume"))
        case "removeMusic":
            _ = try fields([])
            self = .removeMusic
        case "setTitle":
            self = .setTitle(try fields(["title"]).string("title"))
        case "setSummary":
            self = .setSummary(try fields(["summary"]).string("summary"))
        case "transcribe":
            let f = try fields(["language", "replace"])
            self = .transcribe(language: try f.optionalString("language"), replace: try f.optionalBool("replace") ?? false)
        default:
            throw APIError(.invalidCommand, "there is no command “\(name)”; the commands are \(Self.names.joined(separator: ", "))")
        }
    }

    /// The `Background` of `setBackground`, read as strictly as a command (final review, area 1, M1): its `type` and only
    /// that type's keys; colours of four numbers from 0 to 1 (`outOfRange` otherwise), a wallpaper Toma has.
    static func background(_ json: JSONValue) throws(APIError) -> Background {
        let kinds = "\"gradient\", \"color\", \"wallpaper\", \"image\" or \"desktop\""
        guard case let .object(object) = json, case let .string(type)? = object["type"] else {
            throw APIError(.invalidCommand, "setBackground: background is an object with “type”: \(kinds)")
        }
        func fields(_ keys: Set<String>) throws(APIError) -> CommandFields {
            try CommandFields("setBackground", object, keys: keys.union(["type"]), key: "background")
        }
        func color(_ f: CommandFields, _ key: String) throws(APIError) -> RGBA {
            guard let value = f.value(key) else { throw f.missing(key) }
            guard case let .array(items) = value, items.count == 4 else {
                throw APIError(.invalidCommand, "setBackground: background.\(key) is a colour, [r, g, b, a]")
            }
            var parts: [Double] = []
            for item in items {
                guard let part = item.double else {
                    throw APIError(.invalidCommand, "setBackground: background.\(key) is a colour, [r, g, b, a]")
                }
                guard part.isFinite, (0...1).contains(part) else {
                    throw APIError(.outOfRange, "setBackground: each part of background.\(key) is from 0 to 1")
                }
                parts.append(part)
            }
            return RGBA(parts[0], parts[1], parts[2], parts[3])
        }
        switch type {
        case "gradient":
            let f = try fields(["start", "end", "angle"])
            return .gradient(start: try color(f, "start"), end: try color(f, "end"), angle: try f.number("angle"))
        case "color":
            return .color(try color(try fields(["color"]), "color"))
        case "wallpaper":
            let id = try fields(["wallpaper"]).string("wallpaper")
            guard WallpaperPreset.preset(id: id) != nil else {
                throw APIError(
                    .invalidCommand,
                    "setBackground: background.wallpaper is one of \(WallpaperPreset.all.map(\.id).joined(separator: ", "))")
            }
            return .wallpaper(id)
        case "image":
            return .image(file: try fields(["file"]).string("file"))
        case "desktop":
            _ = try fields([])
            return .desktop
        default:
            throw APIError(.invalidCommand, "setBackground: background.type is \(kinds)")
        }
    }

    /// The commands of `data`: one JSON object, or an array of them, in order.
    public static func list(from data: Data) throws(APIError) -> [ProjectCommand] {
        let json: JSONValue
        do { json = try ProjectJSON.decoder().decode(JSONValue.self, from: data) } catch {
            throw APIError(.invalidCommand, "the commands are not JSON")
        }
        if case let .array(items) = json {
            var commands: [ProjectCommand] = []
            for (k, item) in items.enumerated() {
                do throws(APIError) { commands.append(try ProjectCommand(json: item)) } catch {
                    throw APIError(error.code, "command \(k + 1): \(error.message)")
                }
            }
            return commands
        }
        return [try ProjectCommand(json: json)]
    }

    /// Its JSON, the object `init(json:)` reads.
    public var json: JSONValue {
        var object: [String: JSONValue] = ["command": .string(name)]
        func put(_ key: String, _ value: JSONValue?) { if let value { object[key] = value } }
        switch self {
        case let .cut(from, to):
            put("from", .number(from))
            put("to", .number(to))
        case let .trimStart(to):
            put("to", .number(to))
        case let .trimEnd(from):
            put("from", .number(from))
        case let .setSpeed(from, to, speed):
            put("from", .number(from))
            put("to", .number(to))
            put("speed", .number(speed))
        case .removeFillers, .removeMusic:
            break
        case let .shortenPauses(longerThan):
            put("longerThan", .number(longerThan))
        case let .addZoom(from, to, depth, focus):
            put("from", .number(from))
            put("to", .number(to))
            put("depth", depth.map(JSONValue.number))
            put("focus", focus?.json)
        case let .removeZoom(id), let .removeMarker(id), let .applyStyle(id):
            put("id", .string(id))
        case let .setAutoZoom(enabled, followsFocus):
            put("enabled", .bool(enabled))
            put("followsFocus", followsFocus.map(JSONValue.bool))
        case let .addMarker(at, name):
            put("at", .number(at))
            put("name", .string(name))
        case let .renameMarker(id, name):
            put("id", .string(id))
            put("name", .string(name))
        case let .setAspect(aspect):
            put("aspect", .string(aspect.rawValue))
        case let .setBackground(background):
            put("background", (try? JSONValue(encoding: background)) ?? .null)
        case let .setCameraLayout(layout, side):
            put("layout", .string(layout.rawValue))
            put("side", side.map { .string($0.rawValue) })
        case let .addTitleCard(at, title, subtitle):
            put("at", at.json)
            put("title", .string(title))
            put("subtitle", subtitle.map(JSONValue.string))
        case let .addText(from, to, text, x, y):
            put("from", .number(from))
            put("to", .number(to))
            put("text", .string(text))
            put("x", .number(x))
            put("y", .number(y))
        case let .addMusic(theme, volume):
            put("theme", .string(theme))
            put("volume", volume.map(JSONValue.number))
        case let .setTitle(title):
            put("title", .string(title))
        case let .setSummary(summary):
            put("summary", .string(summary))
        case let .transcribe(language, replace):
            put("language", language.map(JSONValue.string))
            put("replace", .bool(replace))
        }
        return .object(object)
    }

    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        do throws(APIError) { try self.init(json: value) } catch { throw error.decodingError(decoder) }
    }

    public func encode(to encoder: any Encoder) throws { try json.encode(to: encoder) }
}

// MARK: - Reading the keys

/// The keys of one command's object, read strictly: a key the command does not take is `invalidCommand`, naming it; a
/// `null` is a key that is not there.
struct CommandFields {
    let command: String
    let object: [String: JSONValue]
    /// What the keys are part of, in messages: the command, or one of its values (`focus`).
    let place: String

    init(_ command: String, _ object: [String: JSONValue], keys: Set<String>, key: String? = nil) throws(APIError) {
        self.command = command
        self.object = object
        place = key.map { "\(command).\($0)" } ?? command
        let allowed = key == nil ? keys.union(["command"]) : keys
        if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            let known = keys.sorted().map { "“\($0)”" }.joined(separator: ", ")
            throw APIError(
                .invalidCommand, "\(place) has no key “\(unknown)”" + (known.isEmpty ? "" : "; its keys are \(known)"))
        }
    }

    func value(_ key: String) -> JSONValue? {
        guard let value = object[key], value != .null else { return nil }
        return value
    }

    func missing(_ key: String) -> APIError { APIError(.invalidCommand, "\(place) needs the key “\(key)”") }

    private func wrong(_ key: String, _ kind: String) -> APIError {
        APIError(.invalidCommand, "\(place): “\(key)” is \(kind)")
    }

    func number(_ key: String) throws(APIError) -> Double {
        guard let value = try optionalNumber(key) else { throw missing(key) }
        return value
    }

    func optionalNumber(_ key: String) throws(APIError) -> Double? {
        guard let value = value(key) else { return nil }
        guard let number = value.double else { throw wrong(key, "a number") }
        return number
    }

    func string(_ key: String) throws(APIError) -> String {
        guard let value = try optionalString(key) else { throw missing(key) }
        return value
    }

    func optionalString(_ key: String) throws(APIError) -> String? {
        guard let value = value(key) else { return nil }
        guard case let .string(string) = value else { throw wrong(key, "a string") }
        return string
    }

    func bool(_ key: String) throws(APIError) -> Bool {
        guard let value = try optionalBool(key) else { throw missing(key) }
        return value
    }

    func optionalBool(_ key: String) throws(APIError) -> Bool? {
        guard let value = value(key) else { return nil }
        guard case let .bool(bool) = value else { throw wrong(key, "true or false") }
        return bool
    }

    /// The value of `key`, one of `cases` by its raw value.
    func raw<T: RawRepresentable>(_ key: String, _ cases: [T]) throws(APIError) -> T where T.RawValue == String {
        guard let value = try optionalRaw(key, cases) else { throw missing(key) }
        return value
    }

    func optionalRaw<T: RawRepresentable>(_ key: String, _ cases: [T]) throws(APIError) -> T? where T.RawValue == String {
        guard let string = try optionalString(key) else { return nil }
        guard let value = cases.first(where: { $0.rawValue == string }) else {
            throw wrong(key, "one of " + cases.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))
        }
        return value
    }
}

extension CameraSide {
    /// Both sides, in order (`CameraSide` is not `CaseIterable`).
    static let all: [CameraSide] = [.start, .end]
}

extension JSONValue {
    /// The value as a `Double`, if it is a number.
    var double: Double? {
        switch self {
        case let .integer(value): Double(value)
        case let .unsigned(value): Double(value)
        case let .number(value): value
        default: nil
        }
    }
}

extension APIError {
    /// This error as `Decodable` says one: the data is not a command.
    func decodingError(_ decoder: any Decoder) -> DecodingError {
        .dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: message, underlyingError: self))
    }
}
