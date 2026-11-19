// SPDX-License-Identifier: GPL-3.0-or-later
// Draws Toma's app icon: writes App/AppIcon.icon, an Icon Composer document (icon.json and its layers as SVG). actool
// compiles it into Assets.car, the layered Liquid Glass icon of macOS 26, and AppIcon.icns, the flat icon that older
// systems show (project.yml names it with ASSETCATALOG_COMPILER_APPICON_NAME).
//   swift scripts/make-app-icon.swift [<output.icon>]
// Nothing in it comes from a drawing app or a download: change a number here, run it again and rebuild. The canvas is Icon Composer's
// 1024 points, which are the tile itself: the system draws the rounded square, the glass, the shadows and the margins of
// the macOS grid. The picture is a take being recorded: the red record dot inside the corner marks of a screen, with the
// island hanging from the notch where Toma lives between the top marks.
import Foundation

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/AppIcon.icon"

// MARK: Design

/// The tile: the brand's violet, light at the top and deep at the bottom; nearly black in the dark appearance.
let tile = (top: p3(0.47, 0.38, 1.00), bottom: p3(0.17, 0.09, 0.55))
let tileDark = (top: p3(0.20, 0.16, 0.40), bottom: p3(0.06, 0.05, 0.14))
/// The record dot: the island's red (`IslandRecordingPanel.red`), white when the system tints the icon.
let recordRed = srgb(1, 0.27059, 0.22745)
let white = srgb(1, 1, 1)
/// The corner marks: white glass, the dark accent (`AccentColor`) in the dark appearance.
let accentDark = p3(0.553, 0.467, 1.0)
let islandBlack = p3(0.04, 0.03, 0.08)

/// The screen the corner marks outline.
let frame = (x: 168.0, y: 196.0, width: 688.0, height: 632.0)
/// A mark's thickness and the length of each of its arms.
let stroke = 68.0, arm = 164.0
/// The outer and inner radius of a mark's corner (continuous).
let outerRadius = 84.0, innerRadius = 22.0
/// The island: a capsule in line with the top marks.
let islandWidth = 184.0
/// The record dot, a little below the middle of the screen to balance the island.
let dot = (x: 512.0, y: 530.0, radius: 160.0)

// MARK: Document

let markPaths = [(1.0, 1.0), (-1.0, 1.0), (-1.0, -1.0), (1.0, -1.0)].map { sx, sy in
    let x = sx > 0 ? frame.x : frame.x + frame.width, y = sy > 0 ? frame.y : frame.y + frame.height
    // An L from its outer corner, clockwise; the end of each arm is a half circle.
    var vertices: [Vertex] = [
        Vertex(0, 0, outerRadius), Vertex(arm, 0, stroke / 2, round: true), Vertex(arm, stroke, stroke / 2, round: true),
        Vertex(stroke, stroke, innerRadius), Vertex(stroke, arm, stroke / 2, round: true), Vertex(0, arm, stroke / 2, round: true),
    ].map { Vertex(x + sx * $0.x, y + sy * $0.y, $0.radius, round: $0.round) }
    if sx * sy < 0 { vertices.reverse() }
    return path(vertices)
}
let island = capsule(x: 512 - islandWidth / 2, y: frame.y, width: islandWidth, height: stroke)

let layers: [(name: String, svg: String)] = [
    ("Record", "<circle cx=\"\(n(dot.x))\" cy=\"\(n(dot.y))\" r=\"\(n(dot.radius))\" fill=\"#FFFFFF\"/>"),
    ("Island", "<path fill=\"#FFFFFF\" d=\"\(island)\"/>"),
    ("Screen", markPaths.map { "<path fill=\"#FFFFFF\" d=\"\($0)\"/>" }.joined(separator: "\n")),
]

func gradient(_ colors: (top: String, bottom: String)) -> JSON {
    .object([
        ("linear-gradient", .array([.string(colors.top), .string(colors.bottom)])),
        ("orientation", .object([
            ("start", .object([("x", .number(0.5)), ("y", .number(0))])),
            ("stop", .object([("x", .number(0.5)), ("y", .number(1))])),
        ])),
    ])
}
func solid(_ color: String) -> JSON { .object([("solid", .string(color))]) }
/// A value for the default appearance and one for `appearance` ("dark", or "tinted": the tinted and clear icons).
func specialized(_ value: JSON, _ others: [(String, JSON)]) -> JSON {
    .array([.object([("value", value)])] + others.map { .object([("appearance", .string($0.0)), ("value", $0.1)]) })
}
func layer(_ name: String, _ properties: [(String, JSON)]) -> JSON {
    .object([("glass", .bool(true)), ("image-name", .string("\(name).svg")), ("name", .string(name))] + properties)
}
func group(_ layer: JSON, shadow: String, shadowOpacity: Double, translucency: Double? = nil) -> JSON {
    var properties: [(String, JSON)] = [
        ("layers", .array([layer])),
        ("shadow", .object([("kind", .string(shadow)), ("opacity", .number(shadowOpacity))])),
    ]
    if let translucency {
        properties.append(("translucency", .object([("enabled", .bool(true)), ("value", .number(translucency))])))
    }
    return .object(properties)
}

// Groups from the front: the dot casts a red glow, the island and the marks a neutral shadow.
let document = JSON.object([
    ("fill-specializations", specialized(gradient(tile), [("dark", gradient(tileDark))])),
    ("groups", .array([
        group(layer("Record", [("fill-specializations", specialized(solid(recordRed), [("tinted", solid(white))]))]),
              shadow: "layer-color", shadowOpacity: 0.5),
        group(layer("Island", [("fill", solid(islandBlack))]), shadow: "neutral", shadowOpacity: 0.3),
        group(layer("Screen", [
            ("fill-specializations", specialized(solid(white), [("dark", solid(accentDark))])),
            // Behind the dot when the system tints the icon, so the dot stays what you see first.
            ("opacity-specializations", specialized(.number(1), [("tinted", .number(0.6))])),
        ]), shadow: "neutral", shadowOpacity: 0.5, translucency: 0.2),
    ])),
    ("supported-platforms", .object([("squares", .string("shared"))])),
])

let fileManager = FileManager.default
try? fileManager.removeItem(atPath: output)
try fileManager.createDirectory(atPath: "\(output)/Assets", withIntermediateDirectories: true)
for (name, body) in layers {
    let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- SPDX-License-Identifier: GPL-3.0-or-later. Written by scripts/make-app-icon.swift: edit that, not this. -->
        <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
        \(body)
        </svg>

        """
    try svg.write(toFile: "\(output)/Assets/\(name).svg", atomically: true, encoding: .utf8)
}
try (document.text(indent: "") + "\n").write(toFile: "\(output)/icon.json", atomically: true, encoding: .utf8)
print("wrote \(output)")

// MARK: Geometry

/// A corner of a path: continuous (Apple's squircle curve) unless `round`, a circular arc.
struct Vertex {
    var x, y, radius: Double
    var round = false
    init(_ x: Double, _ y: Double, _ radius: Double, round: Bool = false) {
        self.x = x; self.y = y; self.radius = radius; self.round = round
    }
    /// How much of each edge next to it the corner takes.
    var extent: Double { round ? radius : radius * 1.52866483 }
}

/// A closed path through `vertices`, clockwise on the canvas (y down). Every edge must be long enough for its corners.
func path(_ vertices: [Vertex]) -> String {
    var d = "", end = ""
    for (index, corner) in vertices.enumerated() {
        let previous = vertices[(index + vertices.count - 1) % vertices.count]
        let next = vertices[(index + 1) % vertices.count]
        let (into, intoLength) = direction(previous, corner), (out, outLength) = direction(corner, next)
        precondition(previous.extent + corner.extent <= intoLength + 1e-9 && corner.extent + next.extent <= outLength + 1e-9,
                     "the corners at (\(corner.x), \(corner.y)) don't fit their edges")
        // A point `back` along the edge into the corner and `ahead` along the edge out of it, in units of the radius.
        func point(_ back: Double, _ ahead: Double) -> String {
            "\(n(corner.x - back * corner.radius * into.x + ahead * corner.radius * out.x)),"
                + "\(n(corner.y - back * corner.radius * into.y + ahead * corner.radius * out.y))"
        }
        let start = point(corner.round ? 1 : 1.52866483, 0)
        // No line where the corners before and after an edge take all of it.
        if index == 0 { d += "M" + start } else if start != end { d += " L" + start }
        end = point(0, corner.round ? 1 : 1.52866483)
        if corner.round {
            let clockwise = into.x * out.y - into.y * out.x > 0
            d += " A\(n(corner.radius)),\(n(corner.radius)) 0 0 \(clockwise ? 1 : 0) \(end)"
        } else {
            d += " C\(point(1.08849323, 0)) \(point(0.86840689, 0.02065986)) \(point(0.66993427, 0.06549600))"
            d += " C\(point(0.37282392, 0.16232095)) \(point(0.16232095, 0.37282392)) \(point(0.06549600, 0.66993427))"
            d += " C\(point(0.02065986, 0.86840689)) \(point(0, 1.08849323)) \(end)"
        }
    }
    return d + " Z"
}

func direction(_ from: Vertex, _ to: Vertex) -> ((x: Double, y: Double), Double) {
    let dx = to.x - from.x, dy = to.y - from.y, length = (dx * dx + dy * dy).squareRoot()
    return ((dx / length, dy / length), length)
}

func capsule(x: Double, y: Double, width: Double, height: Double) -> String {
    let r = height / 2
    return path([Vertex(x, y, r, round: true), Vertex(x + width, y, r, round: true),
                 Vertex(x + width, y + height, r, round: true), Vertex(x, y + height, r, round: true)])
}

// MARK: Output

/// A number as short as it can be written, to a thousandth.
func n(_ value: Double) -> String {
    var text = String(format: "%.3f", value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text == "-0" ? "0" : text
}
func p3(_ r: Double, _ g: Double, _ b: Double) -> String { String(format: "display-p3:%.5f,%.5f,%.5f,1.00000", r, g, b) }
func srgb(_ r: Double, _ g: Double, _ b: Double) -> String { String(format: "srgb:%.5f,%.5f,%.5f,1.00000", r, g, b) }

/// JSON written the way Icon Composer writes it: keys in order, two spaces, " : ".
indirect enum JSON {
    case object([(String, JSON)]), array([JSON]), string(String), number(Double), bool(Bool)

    func text(indent: String) -> String {
        let inner = indent + "  "
        switch self {
        case .object(let members):
            let sorted = members.sorted { $0.0 < $1.0 }
            return "{\n" + sorted.map { "\(inner)\"\($0.0)\" : \($0.1.text(indent: inner))" }.joined(separator: ",\n")
                + "\n\(indent)}"
        case .array(let items):
            return "[\n" + items.map { inner + $0.text(indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
        case .string(let value): return "\"\(value)\""
        case .number(let value): return n(value)
        case .bool(let value): return value ? "true" : "false"
        }
    }
}
