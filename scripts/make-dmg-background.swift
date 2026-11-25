// SPDX-License-Identifier: GPL-3.0-or-later
// Draws the background of the DMG's window: black, one soft violet light along the row of icons, three small chevrons
// from Toma to Applications, and a quiet note on opening Toma the first time if macOS blocks it (Toma isn't notarized).
// scripts/release.sh copies the result into the DMG and puts the icons where `Layout` says, so the picture and the
// icons line up.
//   swift scripts/make-dmg-background.swift [<output.tiff>]
//   swift scripts/make-dmg-background.swift --preview <Toma.app> <light.png> <dark.png>
//   swift scripts/make-dmg-background.swift --layout      (the window's size and the icons' places, for make-dmg.sh)
// The TIFF holds the window at 1x and 2x (tiffutil -cathidpicheck). --preview draws the window as Finder would show it,
// with the real icons and Finder's labels in the light and the dark appearance, and prints how each label contrasts.
// Nothing in it comes from a drawing app or a download: change a number here and run it again.
import AppKit

// MARK: Design

/// The window's content, in points. scripts/release.sh sizes the Finder window to it.
let size = CGSize(width: 640, height: 400)

/// Where Finder puts each icon (its center, from the top left), and the icon size. scripts/release.sh reads these.
enum Layout {
    static let toma = CGPoint(x: 180, y: 200)
    static let applications = CGPoint(x: 460, y: 200)
    static let iconSize = 96.0
    static let textSize = 13.0
}

/// Near black, tinted toward the brand's violet.
let base = NSColor(displayP3Red: 0.035, green: 0.03, blue: 0.055, alpha: 1)
/// The light along the row of icons. Finder writes the icons' names in black in the light appearance and in white in the
/// dark one, so the light is strongest where the names sit; --preview prints the contrast of each.
let violet = NSColor(displayP3Red: 0.50, green: 0.37, blue: 1.00, alpha: 1)

let title = "Drag Toma to Applications"
let subtitle = "Arrastrar Toma a Aplicaciones"
let firstLaunch = (
    english: "First time? System Settings › Privacy & Security › Open Anyway",
    spanish: "¿Primera vez? Ajustes del Sistema › Privacidad y seguridad › Abrir igualmente"
)

// MARK: Drawing

func drawBackground() {
    base.setFill()
    CGRect(origin: .zero, size: size).fill()

    // A wide, low light just under the icons, like a horizon: it carries the names, and nothing else is lit.
    let row = Layout.toma.y + Layout.iconSize / 2 + 12
    radial(center: CGPoint(x: size.width / 2, y: row), radius: 340, squash: 0.2,
           stops: [(violet.withAlphaComponent(0.95), 0), (violet.withAlphaComponent(0.78), 0.5),
                   (violet.withAlphaComponent(0), 1)])
    radial(center: CGPoint(x: size.width / 2, y: row - 30), radius: 300, squash: 0.45,
           stops: [(violet.withAlphaComponent(0.18), 0), (violet.withAlphaComponent(0), 1)])

    let white = NSColor.white
    drawCentered(NSAttributedString(string: title, attributes: [
        .font: NSFont.systemFont(ofSize: 24, weight: .semibold), .kern: -0.3,
        .foregroundColor: white.withAlphaComponent(0.95),
    ]), y: 44)
    drawCentered(NSAttributedString(string: subtitle, attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: white.withAlphaComponent(0.5),
    ]), y: 78)

    drawChevrons()

    drawCentered(NSAttributedString(string: firstLaunch.english, attributes: [
        .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: white.withAlphaComponent(0.6),
    ]), y: 336)
    drawCentered(NSAttributedString(string: firstLaunch.spanish, attributes: [
        .font: NSFont.systemFont(ofSize: 11.5, weight: .regular), .foregroundColor: white.withAlphaComponent(0.42),
    ]), y: 354)
}

/// Three small chevrons between the icons that brighten toward Applications.
func drawChevrons() {
    let middle = CGPoint(x: (Layout.toma.x + Layout.applications.x) / 2, y: Layout.toma.y)
    let height = 16.0, width = 8.0, step = 14.0
    for (index, opacity) in [0.22, 0.48, 0.85].enumerated() {
        let x = middle.x + CGFloat(index - 1) * step
        let chevron = NSBezierPath()
        chevron.move(to: CGPoint(x: x - width / 2, y: middle.y - height / 2))
        chevron.line(to: CGPoint(x: x + width / 2, y: middle.y))
        chevron.line(to: CGPoint(x: x - width / 2, y: middle.y + height / 2))
        chevron.lineWidth = 2.5
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        NSColor.white.withAlphaComponent(opacity).setStroke()
        chevron.stroke()
    }
}

/// A soft light through `stops`; `squash` below 1 flattens it into a wide ellipse.
func radial(center: CGPoint, radius: CGFloat, squash: CGFloat, stops: [(NSColor, CGFloat)]) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: center.x, yBy: center.y)
    transform.scaleX(by: 1, yBy: squash)
    transform.concat()
    var locations = stops.map(\.1)
    NSGradient(colors: stops.map(\.0), atLocations: &locations, colorSpace: .displayP3)!
        .draw(fromCenter: .zero, radius: 0, toCenter: .zero, radius: radius, options: [])
    NSGraphicsContext.restoreGraphicsState()
}

func drawCentered(_ text: NSAttributedString, y: CGFloat) {
    text.draw(at: CGPoint(x: (size.width - text.size().width) / 2, y: y))
}

/// The window as Finder shows it: each icon at its place and its name under it, in the appearance's color.
func drawIcons(app: String, labelColor: NSColor) {
    let workspace = NSWorkspace.shared
    let items: [(NSImage, String, CGPoint)] = [
        (workspace.icon(forFile: app), "Toma", Layout.toma),
        (workspace.icon(forFile: "/Applications"), "Applications", Layout.applications),
    ]
    for (icon, name, center) in items {
        let side = Layout.iconSize
        icon.draw(in: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side),
                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let label = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: Layout.textSize), .foregroundColor: labelColor,
        ])
        label.draw(at: CGPoint(x: center.x - label.size().width / 2, y: center.y + side / 2 + 3))
    }
}

/// A faint, even grain so the light has no bands; the same on every run.
func addGrain(to rep: NSBitmapImageRep, strength: Int = 3) {
    guard let pixels = rep.bitmapData else { return }
    var seed: UInt32 = 0x7E57_0A1A
    for index in 0..<(rep.pixelsWide * rep.pixelsHigh) {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let offset = Int(seed >> 24) % (strength * 2 + 1) - strength
        for channel in 0..<3 {
            let byte = index * 4 + channel
            pixels[byte] = UInt8(clamping: Int(pixels[byte]) + offset)
        }
    }
}

/// Draws into a bitmap `scale` times the window's size, with the origin at the top left like Finder's positions.
func render(scale: CGFloat, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                               pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                               bitsPerPixel: 0)!
    rep.size = size
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    context.cgContext.translateBy(x: 0, y: size.height)
    context.cgContext.scaleBy(x: 1, y: -1)
    drawBackground()
    context.cgContext.flush()
    addGrain(to: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
    }
    try data.write(to: URL(fileURLWithPath: path))
}

/// The contrast of each icon's name on the background, in black (light appearance) and in white (dark appearance).
func printLabelContrast() {
    let rep = render(scale: 1) {}
    func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
    for (name, center) in [("Toma", Layout.toma), ("Applications", Layout.applications)] {
        let top = Int(center.y + Layout.iconSize / 2 + 3)
        var total = 0.0, count = 0.0
        for y in top..<(top + 16) {
            for x in Int(center.x - 30)..<Int(center.x + 30) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
                    + 0.0722 * linear(color.blueComponent)
                count += 1
            }
        }
        let luminance = total / count
        let black = (luminance + 0.05) / 0.05, white = 1.05 / (luminance + 0.05)
        print(String(format: "%@: black %.1f:1 (light appearance), white %.1f:1 (dark appearance)", name, black, white))
    }
}

// MARK: Main

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--layout" {
    // For scripts/make-dmg.sh, so the window and the icons follow the picture.
    print("width=\(Int(size.width)) height=\(Int(size.height)) icon_size=\(Int(Layout.iconSize))",
          "text_size=\(Int(Layout.textSize)) toma_x=\(Int(Layout.toma.x)) toma_y=\(Int(Layout.toma.y))",
          "applications_x=\(Int(Layout.applications.x)) applications_y=\(Int(Layout.applications.y))")
} else if arguments.first == "--preview" {
    guard arguments.count == 4 else {
        FileHandle.standardError.write("usage: make-dmg-background.swift --preview <Toma.app> <light.png> <dark.png>\n".data(using: .utf8)!)
        exit(2)
    }
    try writePNG(render(scale: 2) { drawIcons(app: arguments[1], labelColor: .black) }, to: arguments[2])
    try writePNG(render(scale: 2) { drawIcons(app: arguments[1], labelColor: .white) }, to: arguments[3])
    print("wrote \(arguments[2]) and \(arguments[3])")
    printLabelContrast()
} else {
    let output = arguments.first ?? "build/dmg/background.tiff"
    let folder = URL(fileURLWithPath: output).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let oneX = folder.appendingPathComponent("background.png").path
    let twoX = folder.appendingPathComponent("background@2x.png").path
    try writePNG(render(scale: 1) {}, to: oneX)
    try writePNG(render(scale: 2) {}, to: twoX)
    let tiffutil = Process()
    tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
    tiffutil.arguments = ["-cathidpicheck", oneX, twoX, "-out", output]
    try tiffutil.run()
    tiffutil.waitUntilExit()
    guard tiffutil.terminationStatus == 0 else { exit(tiffutil.terminationStatus) }
    try? FileManager.default.removeItem(atPath: oneX)
    try? FileManager.default.removeItem(atPath: twoX)
    print("wrote \(output)")
}
