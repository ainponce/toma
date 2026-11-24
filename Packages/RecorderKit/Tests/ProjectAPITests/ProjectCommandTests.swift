// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Testing
@testable import ProjectAPI

/// The commands' JSON and their schema (plan 4b decisions 3 and 16).

/// One of each case, with its optional keys.
let everyCommand: [ProjectCommand] = [
    .cut(from: 1, to: 2.5), .trimStart(to: 0.5), .trimEnd(from: 8), .setSpeed(from: 2, to: 4, speed: 2), .removeFillers,
    .shortenPauses(longerThan: 1.2), .addZoom(from: 1, to: 3, depth: 2, focus: .fixed(x: 0.2, y: 0.7)),
    .addZoom(from: 4, to: 6, depth: nil, focus: .follow), .addZoom(from: 4, to: 6, depth: nil, focus: nil), .removeZoom(id: "z-1"),
    .setAutoZoom(enabled: true, followsFocus: true), .setAutoZoom(enabled: false, followsFocus: nil),
    .addMarker(at: 3, name: "Setup"), .renameMarker(id: "m-1", name: "Demo"), .removeMarker(id: "m-1"), .setAspect(.portrait),
    .setBackground(.gradient(start: RGBA(1, 0, 0, 1), end: RGBA(0, 0, 1, 1), angle: 135)), .setBackground(.desktop),
    .setBackground(.image(file: "/Users/someone/Pictures/back.png")), .applyStyle(id: "toma"),
    .setCameraLayout(.split, side: .start), .setCameraLayout(.bubble, side: nil),
    .addTitleCard(at: .start, title: "Hello", subtitle: "World"), .addTitleCard(at: .at(4.5), title: "Two", subtitle: nil),
    .addTitleCard(at: .end, title: "End", subtitle: nil), .addText(from: 1, to: 2, text: "Click", x: 0.5, y: 0.8),
    .addMusic(theme: "calm", volume: -18), .addMusic(theme: "focus", volume: nil), .removeMusic, .setTitle("Title"),
    .setSummary("Summary"), .transcribe(language: "es-AR", replace: true), .transcribe(language: nil, replace: false),
]

@Test func everyCommandRoundTrips() throws {
    #expect(Set(everyCommand.map(\.name)) == Set(ProjectCommand.names))
    for command in everyCommand {
        #expect(try ProjectCommand(json: command.json) == command)
        let data = try ProjectJSON.encoder().encode(command)
        #expect(try ProjectJSON.decoder().decode(ProjectCommand.self, from: data) == command, "\(command.name)")
        #expect(try ProjectCommand.list(from: data) == [command])
        // Its JSON names it.
        guard case let .object(object) = command.json else { throw TestSupportFailure("not an object") }
        #expect(object["command"] == .string(command.name))
    }
}

@Test func unknownCommandAndUnknownKeyAreInvalid() throws {
    func error(_ text: String) -> APIError? {
        do throws(APIError) {
            _ = try ProjectCommand.list(from: Data(text.utf8))
            return nil
        } catch {
            return error
        }
    }
    let unknown = try #require(error(#"{"command":"explode"}"#))
    #expect(unknown.code == .invalidCommand && unknown.message.contains("explode"))
    let key = try #require(error(#"{"command":"cut","from":1,"to":2,"speed":3}"#))
    #expect(key.code == .invalidCommand && key.message.contains("speed"))
    let missing = try #require(error(#"{"command":"cut","from":1}"#))
    #expect(missing.code == .invalidCommand && missing.message.contains("to"))
    let type = try #require(error(#"{"command":"addMarker","at":"soon","name":"x"}"#))
    #expect(type.code == .invalidCommand && type.message.contains("at"))
    let focusKey = try #require(error(#"{"command":"addZoom","from":1,"to":2,"focus":{"x":0.5,"y":0.5,"z":1}}"#))
    #expect(focusKey.code == .invalidCommand && focusKey.message.contains("z"))
    let aspect = try #require(error(#"{"command":"setAspect","aspect":"2:1"}"#))
    #expect(aspect.code == .invalidCommand && aspect.message.contains("16:9"))
    #expect(error(#"{"from":1}"#)?.code == .invalidCommand)
    #expect(error(#"[1]"#)?.code == .invalidCommand)
    #expect(error("not json")?.code == .invalidCommand)
    // A `null` is a key that is not there.
    #expect(try ProjectCommand.list(from: Data(#"{"command":"addZoom","from":1,"to":2,"depth":null}"#.utf8))
        == [.addZoom(from: 1, to: 2, depth: nil, focus: nil)])
}

@Test func aBatchIsAnObjectOrAnArray() throws {
    #expect(try ProjectCommand.list(from: Data(#"{"command":"removeFillers"}"#.utf8)) == [.removeFillers])
    let batch = #"[{"command":"cut","from":1,"to":2},{"command":"setTitle","title":"A"},{"command":"removeMusic"}]"#
    #expect(try ProjectCommand.list(from: Data(batch.utf8)) == [.cut(from: 1, to: 2), .setTitle("A"), .removeMusic])
    #expect(try ProjectCommand.list(from: Data("[]".utf8)) == [])
    do throws(APIError) {
        _ = try ProjectCommand.list(from: Data(#"[{"command":"removeMusic"},{"command":"nope"}]"#.utf8))
        Issue.record("a batch with an unknown command decoded")
    } catch {
        #expect(error.code == .invalidCommand && error.message.hasPrefix("command 2:"))
    }
}

@Test func everySchemaExampleDecodes() throws {
    guard case let .object(root) = CommandSchema.document, case let .object(defs)? = root["$defs"] else {
        throw TestSupportFailure("no $defs")
    }
    var count = 0
    for (name, definition) in defs {
        guard case let .object(schema) = definition, case let .array(examples)? = schema["examples"] else {
            throw TestSupportFailure("\(name) has no examples")
        }
        #expect(!examples.isEmpty, "\(name)")
        for example in examples {
            let command = try ProjectCommand(json: example)
            #expect(command.name == name)
            count += 1
        }
    }
    #expect(count >= ProjectCommand.names.count)
}

@Test func schemaNamesEveryCase() throws {
    guard case let .object(root) = CommandSchema.document, case let .object(defs)? = root["$defs"],
        case let .object(properties)? = root["properties"], case let .object(command)? = properties["command"],
        case let .array(names)? = command["enum"]
    else { throw TestSupportFailure("the schema has no $defs or command enum") }
    #expect(Set(defs.keys) == Set(ProjectCommand.names))
    #expect(names == ProjectCommand.names.map(JSONValue.string))
    #expect(ProjectCommand.names.count == 23)
    #expect(Set(everyCommand.map(\.name)).count == ProjectCommand.names.count)
    #expect(root["$schema"] == .string("https://json-schema.org/draft/2020-12/schema"))
    // Each one's `command` is its name, and the keys it needs are in its properties.
    for (name, definition) in defs {
        guard case let .object(schema) = definition, case let .object(keys)? = schema["properties"],
            case let .array(required)? = schema["required"]
        else { throw TestSupportFailure("\(name) is not an object schema") }
        #expect(keys["command"] == .object(["const": .string(name)]))
        for key in required {
            guard case let .string(key) = key else { continue }
            #expect(keys[key] != nil, "\(name).\(key)")
        }
        #expect(schema["additionalProperties"] == nil)
    }
}

@Test func inlineHasNoRef() throws {
    func hasRef(_ value: JSONValue) -> Bool {
        switch value {
        case let .object(object): object.keys.contains("$ref") || object.values.contains(where: hasRef)
        case let .array(array): array.contains(where: hasRef)
        default: false
        }
    }
    #expect(!hasRef(CommandSchema.inline))
    #expect(hasRef(CommandSchema.document))
    guard case let .object(root) = CommandSchema.inline, case let .array(oneOf)? = root["oneOf"] else {
        throw TestSupportFailure("no oneOf")
    }
    #expect(root["$defs"] == nil)
    #expect(oneOf.count == ProjectCommand.names.count)
}

/// A failure of a test's own check.
struct TestSupportFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

@Test func aBackgroundIsReadStrictly() throws {
    func error(_ background: String) -> APIError? {
        do throws(APIError) {
            let text = ##"{"command":"setBackground","background":"## + background + "}"
            _ = try ProjectCommand.list(from: Data(text.utf8))
            return nil
        } catch {
            return error
        }
    }
    let bogus = try #require(error(#"{"type":"color","color":[1,0,0,1],"bogus":1}"#))
    #expect(bogus.code == .invalidCommand && bogus.message.contains("bogus"))
    #expect(error(#"{"type":"color","color":[2,-1,0,1]}"#)?.code == .outOfRange)
    #expect(error(#"{"type":"color","color":[1,0,0]}"#)?.code == .invalidCommand)
    #expect(error(#"{"color":[1,0,0,1]}"#)?.code == .invalidCommand)
    let wallpaper = try #require(error(#"{"type":"wallpaper","wallpaper":"nope-9"}"#))
    #expect(wallpaper.code == .invalidCommand && wallpaper.message.contains("aurora-1"))
    #expect(error(#"{"type":"desktop","file":"x"}"#)?.code == .invalidCommand)
    #expect(error(#"{"type":"gradient","start":[1,0,0,1],"end":[0,0,1,1],"angle":90}"#) == nil)
    #expect(error(#"{"type":"wallpaper","wallpaper":"aurora-1"}"#) == nil)
}
