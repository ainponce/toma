// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import ProjectFormat
import ProjectJobs
import Render
import SwiftUI
import UniformTypeIdentifiers

/// The camera's picture in the Camera tab (phase 2 design §6.1 to §6.3, plan 2b task I13), under its look:
///
/// - **Background:** Original, Blurred or Removed, with "Preparing the cutout… 30 %" while the person's masks are made (the
///   camera is drawn as recorded meanwhile) or why they could not be.
/// - **Framing:** Centered, Follow Face or Manual, and the zoom (in every mode: Centered above 1× is the middle of the
///   picture). Follow Face says "Looking for the face… 40 %" while the faces are found (the camera stays centered
///   meanwhile); Manual has the small view of the camera's frame at the playhead with its crop (`CameraFramingView`).
/// - **Color:** a tile for each look made in code, each showing the camera's frame at the playhead with it (a sample scene
///   until there is one), Custom with the user's `.cube` (the reason when one is refused), and Intensity.
///
/// The camera's frame is the one the preview draws at the playhead (`FrameRenderer`'s scene: its track, its instant, its
/// shape), made off the main thread once the playhead stops (`CameraStill`). The rules are `CameraPictureRules` and
/// `CameraFramingDrag`; this view only draws them.
struct CameraPictureSections: View {
    let model: EditorModel
    let document: EditDocument

    @State private var still: CameraStillPicture?
    @State private var stillMissing = false
    @State private var shape = CameraShapeSeen.bubble
    @State private var looks: [CameraColorPreset: CGImage] = [:]
    /// Whether `looks` are of `still` (rather than of the sample scene).
    @State private var looksOfStill = false
    @State private var lutImport = Self.initialLUTImport
    /// The framing a drag of the small view or of the zoom bar shows while it lasts.
    @State private var liveFraming: CameraFraming?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The longer side of the still, in pixels: the panel's widest at 2×.
    private static let stillSide = 720
    /// The longer side of a tile's picture, in pixels.
    private static let tileSide = 200

    var body: some View {
        // Paused, the camera the preview draws at the playhead; playing, the last one (nothing is asked for meanwhile).
        let seen = model.isPlaying ? nil : cameraAtPlayhead()
        VStack(alignment: .leading, spacing: 18) {
            Divider()
            background
            Divider()
            framing
            Divider()
            color
        }
        .onChange(of: seen?.shape, initial: true) { _, new in
            if let new { shape = new }
        }
        .task(id: seen?.key) {
            if let seen { await loadStill(seen.key, take: seen.take) }
        }
        .task(id: still?.key) { await makeLooks() }
        .onChange(of: document.camera.framing) { _, _ in
            if !model.isGesturing { liveFraming = nil }
        }
    }

    // MARK: - Background

    private var background: some View {
        let value = document.camera.background
        let problem = model.image.problem(document, .masks)
        let status = CameraPictureRules.status(progress: model.image.cameraProgress(document, .masks), failed: problem != nil)
        return PanelSection("Background") {
            ModeSegments(
                title: "Background", selection: value,
                options: [
                    .init(name: "Original", symbol: "person.crop.rectangle", value: .original),
                    .init(name: "Blurred", symbol: "person.and.background.dotted", value: .blurred),
                    .init(name: "Removed", symbol: "person.and.background.striped.horizontal", value: .removed),
                ]
            ) { model.setCameraBackground($0) }
            AnalysisLine(status: status, job: .masks, problem: problem)
            if value == .removed {
                Text("In a bubble, only the person shows, without its shape, border or shadow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(PictureMotion.appearing)
            }
        }
        .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: value)
        .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: AnalysisLine.phase(of: status))
    }

    // MARK: - Framing

    private var framing: some View {
        let framing = document.camera.framing
        let problem = framing.mode == .face ? model.image.problem(document, .faces) : nil
        let status =
            framing.mode == .face
            ? CameraPictureRules.status(progress: model.image.cameraProgress(document, .faces), failed: problem != nil) : .none
        return PanelSection("Framing") {
            ModeSegments(
                title: "Framing", selection: framing.mode,
                options: [
                    .init(name: "Centered", symbol: "dot.viewfinder", value: .center),
                    .init(name: "Follow Face", symbol: "person.fill.viewfinder", value: .face),
                    .init(name: "Manual", symbol: "hand.draw", value: .manual),
                ]
            ) { model.setFramingMode($0) }
            AnalysisLine(status: status, job: .faces, problem: problem)
            if framing.mode == .manual {
                VStack(alignment: .leading, spacing: 6) {
                    CameraFramingView(
                        model: model, still: still, stillMissing: stillMissing, shape: shape, mirrored: document.camera.mirror,
                        framing: framing, live: $liveFraming)
                    Text("Drag to move the framing; scroll or pinch to zoom.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(PictureMotion.appearing)
            }
            FramingZoomBar(model: model, framing: framing, live: $liveFraming)
        }
        .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: framing.mode)
        .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: AnalysisLine.phase(of: status))
    }

    // MARK: - Color

    private var color: some View {
        let look = document.camera.look
        let selected = CameraPictureRules.selectedLook(look)
        return PanelSection("Color") {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 3), alignment: .leading,
                spacing: 10
            ) {
                ForEach(CameraPictureRules.presets, id: \.self) { preset in
                    LookTile(
                        name: Self.name(preset), image: looks[preset], mirrored: looksOfStill && document.camera.mirror,
                        isSelected: selected == preset
                    ) { choose(preset) }
                }
            }
            customRow(look, isSelected: selected == .custom)
            PanelSlider(
                title: "Intensity", model: model, value: Int((look.intensity * 100).rounded()), range: 0...100, unit: " %"
            ) { model.setLookIntensity(Double($0) / 100) }
            .disabled(!CameraPictureRules.intensityApplies(look))
        }
        .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: lutImport)
    }

    @ViewBuilder
    private func customRow(_ look: CameraColor, isSelected: Bool) -> some View {
        if lutImport == .importing {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Bringing in the .cube…")
                Spacer(minLength: 8)
                Button("Cancel") { model.cancelImageImport() }
            }
            .transition(PictureMotion.appearing)
        } else {
            let hasFile = look.lut != nil
            HStack(spacing: 10) {
                Button {
                    choose(.custom)
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(hasFile ? 0.45 : 0.2), Color.primary.opacity(0.08)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .frame(width: 44, height: 33)
                            .overlay {
                                Image(systemName: hasFile ? "cube.fill" : "cube")
                                    .foregroundStyle(hasFile ? Color.primary : Color.secondary)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(
                                        isSelected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: isSelected ? 2.5 : 1)
                            }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hasFile ? "Custom" : "Custom…")
                                .fontWeight(isSelected ? .semibold : .regular)
                            Text(hasFile ? "The imported .cube file" : "A 3D LUT in a .cube file")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(hasFile ? "Custom" : "Custom…"))
                .accessibilityHint(Text(hasFile ? "The imported .cube file" : "A 3D LUT in a .cube file"))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                if hasFile {
                    Button("Change…", action: chooseCube)
                        .help(Text("Choose another .cube file"))
                }
            }
            lutProblem
        }
    }

    @ViewBuilder
    private var lutProblem: some View {
        let reason: String? =
            switch lutImport {
            case let .refused(error): Self.reason(error)
            case .unreadable: String(localized: "Couldn't open the file.")
            case .saveFailed: String(localized: "The file couldn't be saved.")
            case .idle, .importing: nil
            }
        if let reason {
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn't use the .cube.")
                    .fontWeight(.semibold)
                    .foregroundStyle(.red)
                Text(verbatim: reason)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .transition(PictureMotion.appearing)
        }
    }

    // MARK: - Doing

    /// A tile of Color: its look, or the open panel for Custom without a `.cube`.
    private func choose(_ preset: CameraColorPreset) {
        switch CameraPictureRules.action(choosing: preset, in: document.camera.look) {
        case let .setPreset(next):
            lutImport = .idle
            model.setLookPreset(next)
        case .chooseFile:
            chooseCube()
        }
    }

    /// "Custom…" or "Change…": a `.cube` from the open panel, brought into the project.
    private func chooseCube() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a 3D LUT in .cube format.")
        let model = model
        let state = $lutImport
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            if model.chooseLUT(url, finished: { state.wrappedValue = $0 }) { state.wrappedValue = .importing }
        }
        if let window = model.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// The camera the preview draws at the playhead: its track and instant, and its shape, of the take of the clip there
    /// (3d plan decision 17). Not drawn there (hidden, a Screen only block), that take's camera at the playhead's source
    /// instant, without a shape.
    private func cameraAtPlayhead() -> SeenCamera? {
        let now = model.playheadNanoseconds
        guard let take = model.playheadProject?.take else { return nil }
        if let scene = model.shownScene, let layer = scene.frame(at: Double(now) / 1e9, cursorImageIsReadable: { _ in true }).camera,
            layer.rect.width > 0, layer.rect.height > 0
        {
            let side = min(layer.rect.width, layer.rect.height)
            return SeenCamera(
                key: CameraStillKey(track: layer.trackID, time: layer.sourceTime), take: take.id,
                shape: CameraShapeSeen(aspect: layer.rect.width / layer.rect.height, cornerFraction: layer.cornerRadius / side))
        }
        guard let track = take.tracks.first(where: { $0.kind == .camera }),
            let found = TimeMap(sequence: document.sequence).source(atOutput: now)
        else { return nil }
        return SeenCamera(key: CameraStillKey(track: track.id, time: found.source), take: take.id, shape: nil)
    }

    /// The still of `key` of take `take`, once the playhead stays there (scrubbing asks for none).
    private func loadStill(_ key: CameraStillKey, take: String) async {
        guard still?.key != key else { return }
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled, let project = model.project(ofTake: take) else { return }
        let found = await CameraStill.frame(project: project, track: key.track, at: key.time, maxPixelSide: Self.stillSide)
        guard !Task.isCancelled else { return }
        if let found {
            still = CameraStillPicture(image: found.image, frameSize: found.frameSize, key: key)
            stillMissing = false
        } else {
            still = nil
            stillMissing = true
        }
    }

    /// Each look on the still, or on the sample scene without one, off the main thread.
    private func makeLooks() async {
        let source = still?.image, side = Self.tileSide
        let made = await Task.detached(priority: .userInitiated) { () -> [CameraColorPreset: CGImage] in
            guard let image = source ?? CameraStill.sampleScene(width: 160, height: 120) else { return [:] }
            var looks: [CameraColorPreset: CGImage] = [:]
            for preset in CameraPictureRules.presets {
                looks[preset] = CameraStill.withLook(preset, image, maxPixelSide: side)
            }
            return looks
        }.value
        guard !Task.isCancelled else { return }
        looks = made
        looksOfStill = source != nil
    }

    /// What the Custom row says first: nothing.
    private static var initialLUTImport: LUTImportState {
        #if DEBUG
        // `-TomaShowcase` with TOMA_SHOWCASE_LUT=refused: a `.cube` refused, to look at its words.
        if ProcessInfo.processInfo.environment["TOMA_SHOWCASE_LUT"] == "refused" {
            return .refused(.wrongCount(expected: 35_937, found: 35_000))
        }
        #endif
        return .idle
    }

    // MARK: - Words

    static func name(_ preset: CameraColorPreset) -> LocalizedStringKey {
        switch preset {
        case .natural: "Natural"
        case .warm: "Warm"
        case .cool: "Cool"
        case .vivid: "Vivid"
        case .soft: "Soft"
        case .mono: "Black & White"
        case .custom: "Custom"
        }
    }

    /// Why a `.cube` was refused (`CubeLUTError`), under "Couldn't use the .cube.".
    static func reason(_ error: CubeLUTError) -> String {
        switch error {
        case .notText:
            String(localized: "It isn't text: it may be an image or another kind of file.")
        case .oneDimensional:
            String(localized: "It's a 1D LUT; it needs a 3D one.")
        case .missingSize:
            String(localized: "It doesn't say its size (LUT_3D_SIZE).")
        case let .sizeOutOfRange(size):
            String(format: String(localized: "Its size is %@; it must be from 2 to 65.", comment: "A .cube's LUT_3D_SIZE"), size.formatted())
        case let .wrongCount(expected, found):
            String(
                format: String(localized: "It has %1$@ rows; its size needs %2$@.", comment: "The rows of a .cube's table"),
                found.formatted(), expected.formatted())
        case let .badNumber(line):
            String(format: String(localized: "Line %@ can't be read.", comment: "A line of a .cube file"), line.formatted())
        case .badDomain:
            String(localized: "Its domain is wrong: each minimum must be below its maximum.")
        case .tooLarge:
            String(localized: "It's larger than 16 MB.")
        }
    }
}

/// A choice of modes as segments of the panel's width, each its symbol over its word (which takes two lines rather than
/// being cut: Spanish is long), the chosen one on an indicator that moves by `Motion.selector` (a fade with "Reduce
/// motion"). With it focused, ← and → choose the neighbouring mode. VoiceOver reads it as a group of buttons, the chosen
/// one selected.
private struct ModeSegments<Value: Hashable>: View {
    struct Option {
        var name: LocalizedStringKey
        var symbol: String
        var value: Value
    }

    let title: LocalizedStringKey
    let selection: Value
    let options: [Option]
    let choose: (Value) -> Void

    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                segment(options[index])
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .focusable()
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = option.value == selection
        return Button {
            pick(option.value)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: option.symbol)
                    .font(.system(size: 15, weight: .regular))
                    .frame(height: 19)
                // Laid out as the chosen word (bolder) whether chosen or not, so choosing never rewraps it.
                Text(option.name)
                    .fontWeight(.semibold)
                    .hidden()
                    .overlay {
                        Text(option.name)
                            .fontWeight(isSelected ? .semibold : .regular)
                    }
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.3))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1))
                        .matchedGeometryEffect(id: "indicator", in: indicator)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(option.name))
        .accessibilityLabel(Text(option.name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func pick(_ value: Value) {
        guard value != selection else { return }
        withAnimation(.panel(Motion.selector, reduceMotion: reduceMotion)) { choose(value) }
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        guard let index = options.firstIndex(where: { $0.value == selection }) else { return .ignored }
        let next = min(max(index + offset, 0), options.count - 1)
        if next != index { pick(options[next].value) }
        return .handled
    }
}

/// The camera the preview draws at the playhead, for its still and its shape.
private struct SeenCamera: Equatable {
    var key: CameraStillKey
    /// The take of the clip at the playhead, whose camera it is.
    var take: String
    /// `nil` where the camera is not drawn.
    var shape: CameraShapeSeen?
}

private enum PictureMotion {
    /// How a line of the Camera tab's picture comes and goes: it fades in where it opens, and leaves at once, so it is
    /// never drawn over what moves up into its place.
    static var appearing: AnyTransition { .asymmetric(insertion: .opacity, removal: .identity) }
}

/// The line of an analysis of the camera (its masks, its faces): how far it is, with a bar, and what is drawn meanwhile;
/// or why it could not be made.
private struct AnalysisLine: View {
    let status: CameraAnalysisStatus
    let job: EditorImage.CameraJob
    let problem: JobProblem?

    /// What the line shows, without its percentage: its appearing and leaving are animated, its number is not.
    static func phase(of status: CameraAnalysisStatus) -> Int {
        switch status {
        case .none: 0
        case .preparing: 1
        case .failed: 2
        }
    }

    var body: some View {
        switch status {
        case .none:
            EmptyView()
        case let .preparing(percent):
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: progressText(percent))
                    .monospacedDigit()
                    .animation(nil, value: percent)
                ProgressView(value: Double(percent), total: 100)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                Text(meanwhile)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .transition(PictureMotion.appearing)
        case .failed:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: failureText)
                    Text(meanwhileAfterFailure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .transition(PictureMotion.appearing)
        }
    }

    private func progressText(_ percent: Int) -> String {
        switch job {
        case .masks:
            String(format: String(localized: "Preparing the cutout… %lld %%", comment: "The camera's background being prepared"), percent)
        case .faces:
            String(format: String(localized: "Looking for the face… %lld %%", comment: "The camera's face being found, for Follow Face"), percent)
        }
    }

    private var meanwhile: LocalizedStringKey {
        switch job {
        case .masks: "Until then, the camera is shown as recorded."
        case .faces: "Until then, the camera stays centered."
        }
    }

    private var meanwhileAfterFailure: LocalizedStringKey {
        switch job {
        case .masks: "The camera is shown as recorded."
        case .faces: "The camera stays centered."
        }
    }

    private var failureText: String {
        let reason = problem.map(EditorImage.reason(of:)) ?? String(localized: "an unexpected error occurred")
        return switch job {
        case .masks:
            String(format: String(localized: "Couldn't prepare the cutout: %@", comment: "The camera's background, and why"), reason)
        case .faces:
            String(format: String(localized: "Couldn't follow the face: %@", comment: "The camera's Follow Face, and why"), reason)
        }
    }
}

/// A tile of Color: the camera's frame (or the sample scene) with its look, its name under it, a ring when it is the one
/// chosen.
private struct LookTile: View {
    let name: LocalizedStringKey
    let image: CGImage?
    let mirrored: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Color.primary.opacity(0.08)
                    .aspectRatio(4.0 / 3, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .interpolation(.medium)
                                .scaledToFill()
                                .scaleEffect(x: mirrored ? -1 : 1, y: 1)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: isSelected ? 2.5 : 1)
                    }
                Text(name)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(name))
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The framing's zoom, 1.0× to 2.5× by tenths (design §6.2). A drag is a gesture of the model (the preview follows it, one
/// edit at the end); an arrow key is a step of its own.
private struct FramingZoomBar: View {
    let model: EditorModel
    /// The document's framing.
    let framing: CameraFraming
    @Binding var live: CameraFraming?

    @State private var editing = false

    var body: some View {
        let zoom = (live ?? framing).zoom
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Zoom")
                Spacer()
                Text(verbatim: CameraZoomText.text(zoom))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { zoom },
                    set: { new in
                        let snapped = CameraPictureRules.snappedZoom(new)
                        guard snapped != zoom else { return }
                        if editing { live = CameraFraming(mode: framing.mode, center: (live ?? framing).center, zoom: snapped) }
                        model.setFramingZoom(snapped)
                    }),
                in: CameraFraming.zoomRange, step: CameraPictureRules.zoomStep,
                onEditingChanged: { began in
                    if began {
                        guard !model.isGesturing, model.canEdit else { return }
                        editing = true
                        live = live ?? framing
                        model.beginGesture()
                    } else if editing {
                        editing = false
                        let changed = model.endGesture()
                        if !changed || model.document?.camera.framing == live { live = nil }
                    }
                }
            )
            .labelsHidden()
            .accessibilityLabel(Text("Zoom"))
            .accessibilityValue(Text(verbatim: CameraZoomText.text(zoom)))
        }
    }
}
