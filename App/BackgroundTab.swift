// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import ProjectFormat
import Render
import SwiftUI
import UniformTypeIdentifiers

/// What kind of background the panel's selector says (design §5.4).
enum BackgroundKind: CaseIterable {
    case wallpaper, gradient, color, image, desktop

    init(_ background: Background) {
        switch background {
        case .wallpaper: self = .wallpaper
        case .gradient: self = .gradient
        case .color: self = .color
        case .image: self = .image
        case .desktop: self = .desktop
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .wallpaper: "Wallpaper"
        case .gradient: "Gradient"
        case .color: "Color"
        case .image: "Image"
        case .desktop: "Desktop"
        }
    }
}

/// The names of Toma's wallpapers and gradients, by their versioned id.
enum BackgroundNames {
    static func wallpaper(_ id: String) -> LocalizedStringKey {
        switch id {
        case "aurora-1": "Aurora"
        case "dune-1": "Dune"
        case "lake-1": "Lake"
        case "ember-1": "Ember"
        case "mist-1": "Mist"
        case "forest-1": "Forest"
        case "lavender-1": "Lavender"
        case "midnight-1": "Midnight"
        case "coral-1": "Coral"
        case "ice-1": "Ice"
        case "graphite-1": "Graphite"
        case "sand-1": "Sand"
        default: LocalizedStringKey(id)
        }
    }

    static func gradient(_ id: String) -> LocalizedStringKey {
        switch id {
        case "toma-classic-1": "Toma Classic"
        case "sunset-1": "Sunset"
        case "ocean-1": "Ocean"
        case "meadow-1": "Meadow"
        case "berry-1": "Berry"
        case "peach-1": "Peach"
        case "dusk-1": "Dusk"
        case "steel-1": "Steel"
        case "citrus-1": "Citrus"
        case "mint-1": "Mint"
        default: LocalizedStringKey(id)
        }
    }
}

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), 1)
    }
}

/// The Background tab (design §5.4): the type, what the type offers, the blur where it applies, the padding, the corners and
/// the shadow. The style for new projects is the panel's row Style (1c design §8, `StyleRow`).
struct BackgroundTab: View {
    let model: EditorModel
    let style: StageStyle

    /// The kind chosen that the document does not have yet (Image, until a file is chosen).
    @State private var pendingKind: BackgroundKind?
    @State private var customGradient = false

    private static let swatches: [UInt32] = [
        0x111113, 0xF2F2F7, 0x0A84FF, 0x30D158, 0xFF453A, 0xFF9F0A, 0xFFD60A, 0xBF5AF2, 0xFF375F, 0x64D2FF,
    ]

    private var kind: BackgroundKind { pendingKind ?? BackgroundKind(style.background) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelSection {
                Picker("Type", selection: Binding(get: { kind }, set: choose)) {
                    ForEach(BackgroundKind.allCases, id: \.self) { kind in
                        Text(kind.title)
                            .tag(kind)
                    }
                }
                if !model.hasDesktopPhoto {
                    Text("This recording has no photo of the desktop.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                switch kind {
                case .wallpaper: wallpapers
                case .gradient: gradients
                case .color: colors
                case .image: image
                case .desktop: EmptyView()
                }
            }
            PanelSection {
                if kind == .wallpaper || kind == .image || kind == .desktop {
                    PanelSlider(
                        title: "Blur", model: model, value: PanelValues.slider(backgroundBlur: style.backgroundBlur)
                    ) {
                        model.setStyle("/style/backgroundBlur", PanelValues.backgroundBlur(slider: $0), label: .background)
                    }
                }
                PanelSlider(title: "Padding", model: model, value: PanelValues.slider(padding: style.padding)) {
                    model.setStyle("/style/padding", PanelValues.padding(slider: $0), label: .padding)
                }
                PanelSlider(title: "Corners", model: model, value: PanelValues.slider(cornerRadius: style.cornerRadius)) {
                    model.setStyle("/style/cornerRadius", PanelValues.cornerRadius(slider: $0), label: .cornerRadius)
                }
                PanelSlider(title: "Shadow", model: model, value: PanelValues.slider(shadow: style.shadow)) {
                    model.setStyle("/style/shadow", PanelValues.shadow(slider: $0), label: .shadow)
                }
            }
        }
        .onChange(of: style.background) { _, new in
            if pendingKind != nil, BackgroundKind(new) == .image { pendingKind = nil }
            if case .gradient = new {} else { customGradient = false }
        }
    }

    // MARK: - The type

    private func choose(_ new: BackgroundKind) {
        guard new != kind else { return }
        switch new {
        case .wallpaper:
            pendingKind = nil
            model.setBackground(DefaultStyle.toma.style.background)
        case .gradient:
            pendingKind = nil
            model.setBackground(.tomaClassic)
        case .color:
            pendingKind = nil
            model.setBackground(.color(RGBA(Self.swatches[0])))
        case .image:
            if case .image = style.background { pendingKind = nil } else { pendingKind = .image }
        case .desktop:
            guard model.hasDesktopPhoto else { return }
            pendingKind = nil
            model.setBackground(.desktop, blur: 0.5)
        }
    }

    // MARK: - Wallpapers, gradients, colours

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 8), count: 3) }

    private var wallpapers: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(WallpaperPreset.all, id: \.id) { preset in
                VStack(spacing: 3) {
                    PanelTile(name: BackgroundNames.wallpaper(preset.id), isSelected: style.background == .wallpaper(preset.id)) {
                        model.setBackground(.wallpaper(preset.id))
                    } swatch: {
                        WallpaperThumbnail(preset: preset)
                            .aspectRatio(16.0 / 10, contentMode: .fit)
                    }
                    Text(BackgroundNames.wallpaper(preset.id))
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(style.background == .wallpaper(preset.id) ? .primary : .secondary)
                }
            }
        }
    }

    private var gradients: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(GradientPresets.all, id: \.id) { preset in
                    let background = Background.gradient(start: preset.start, end: preset.end, angle: preset.angle)
                    VStack(spacing: 3) {
                        PanelTile(name: BackgroundNames.gradient(preset.id), isSelected: style.background == background) {
                            customGradient = false
                            model.setBackground(background)
                        } swatch: {
                            GradientSwatch(start: preset.start, end: preset.end, angle: preset.angle)
                                .aspectRatio(16.0 / 10, contentMode: .fit)
                        }
                        Text(BackgroundNames.gradient(preset.id))
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(style.background == background ? .primary : .secondary)
                    }
                }
                VStack(spacing: 3) {
                    PanelTile(name: "Custom", isSelected: isCustomGradient) {
                        customGradient = true
                    } swatch: {
                        Image(systemName: "slider.horizontal.3")
                            .frame(maxWidth: .infinity)
                            .aspectRatio(16.0 / 10, contentMode: .fit)
                            .background(Color.primary.opacity(0.08))
                    }
                    Text("Custom")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if isCustomGradient, case let .gradient(start, end, angle) = style.background {
                HStack {
                    ColorPicker(
                        "Start Color",
                        selection: Binding(
                            get: { start.color }, set: { model.setBackground(.gradient(start: RGBA($0), end: end, angle: angle)) }))
                    ColorPicker(
                        "End Color",
                        selection: Binding(
                            get: { end.color }, set: { model.setBackground(.gradient(start: start, end: RGBA($0), angle: angle)) }))
                }
                PanelSlider(title: "Angle", model: model, value: Int(angle.rounded()), range: 0...360) {
                    model.setBackground(.gradient(start: start, end: end, angle: Double($0)))
                }
            } else if isCustomGradient {
                EmptyView()
            }
        }
    }

    /// A gradient that is none of Toma's, or the Custom tile asked for.
    private var isCustomGradient: Bool {
        guard case let .gradient(start, end, angle) = style.background else { return false }
        return customGradient || !GradientPresets.all.contains { $0.start == start && $0.end == end && $0.angle == angle }
    }

    private var colors: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(Self.swatches, id: \.self) { hex in
                    PanelTile(name: "Color", isSelected: style.background == .color(RGBA(hex))) {
                        model.setBackground(.color(RGBA(hex)))
                    } swatch: {
                        RGBA(hex).color
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
            if case let .color(current) = style.background {
                ColorPicker(
                    "Color", selection: Binding(get: { current.color }, set: { model.setBackground(.color(RGBA($0))) }),
                    supportsOpacity: false)
            }
        }
    }

    // MARK: - Image

    @ViewBuilder
    private var image: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case let .image(file) = style.background {
                BackgroundImageThumbnail(model: model, file: file)
            }
            switch model.imageImport {
            case .importing:
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving the image…")
                    Spacer()
                    Button("Cancel") { model.cancelImageImport() }
                }
            case .idle, .notAnImage, .saveFailed:
                Button("Choose Image…", action: chooseImage)
                if case .image = style.background {
                    Button("Remove Image") { model.removeImage() }
                }
                if model.imageImport == .notAnImage {
                    Text("Couldn't open the image.")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if model.imageImport == .saveFailed {
                    Text("The image couldn't be saved.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = EditorModel.ImportedFile.image.contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let model = model
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            model.chooseImage(url)
        }
        if let window = model.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}

private extension RGBA {
    /// `0xRRGGBB`.
    init(_ hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, 1)
    }
}

/// A wallpaper in small: its colours as soft spots over the average of them (an approximation of the render's mesh).
private struct WallpaperThumbnail: View {
    let preset: WallpaperPreset

    var body: some View {
        Canvas { context, size in
            let colors = preset.colors.map { Color(.sRGB, red: Double($0.x), green: Double($0.y), blue: Double($0.z), opacity: 1) }
            let average = preset.colors.reduce(SIMD4<Float>.zero, +) / Float(max(preset.colors.count, 1))
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(.sRGB, red: Double(average.x), green: Double(average.y), blue: Double(average.z), opacity: 1)))
            for (point, color) in zip(preset.points, colors) {
                let center = CGPoint(x: CGFloat(point.x) * size.width, y: CGFloat(point.y) * size.height)
                let radius = max(size.width, size.height) * 0.6
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)),
                    with: .radialGradient(
                        Gradient(colors: [color, color.opacity(0)]), center: center, startRadius: 0, endRadius: radius))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct GradientSwatch: View {
    let start: RGBA
    let end: RGBA
    let angle: Double

    var body: some View {
        let ends = PanelValues.gradientEnds(angle: angle)
        LinearGradient(
            colors: [start.color, end.color], startPoint: UnitPoint(x: ends.start.x, y: ends.start.y),
            endPoint: UnitPoint(x: ends.end.x, y: ends.end.y)
        )
        .accessibilityHidden(true)
    }
}

/// The image of an image background, read from the project off the main thread.
private struct BackgroundImageThumbnail: View {
    let model: EditorModel
    let file: String
    @State private var picture: NSImage?

    var body: some View {
        Group {
            if let picture {
                Image(nsImage: picture)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.primary.opacity(0.08)
                    .aspectRatio(16.0 / 10, contentMode: .fit)
            }
        }
        .frame(maxHeight: 120)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
        .task(id: file) {
            guard let package = model.overlayProject?.package else { return }
            let name = file
            let cg = await Task.detached { package.asset(name) }.value
            picture = cg.map { NSImage(cgImage: $0, size: .zero) }
        }
    }
}
