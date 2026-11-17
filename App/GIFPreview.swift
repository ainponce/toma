// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import SwiftUI

/// The preview GIF as `NSImageView` plays it: decoded by ImageIO (`NSImage`), set to loop whatever "Loop Forever" says
/// (the preview plays in a loop, 1c design §7.3), with its size in pixels.
struct GIFPreviewImage {
    /// Which request made it.
    let id: Int
    let image: NSImage
    let pixels: CGSize

    init?(_ data: Data, id: Int) {
        guard let image = NSImage(data: data), let rep = image.representations.first as? NSBitmapImageRep else { return nil }
        rep.setProperty(.loopCount, withValue: 0)
        self.id = id
        self.image = image
        pixels = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}

/// The GIF's preview (1c design §7.3): the real GIF, in a loop, fitted to 320 × 180 pt; Actual Size shows it 1:1 with
/// the screen's pixels in a view that scrolls (the dither is only judged so). With "Reduce motion" it does not start by
/// itself: the first frame, and a button to play it. "Making the preview…" over it while it is made again. VoiceOver
/// calls it "GIF Preview" and says whether it plays.
struct GIFPreviewBox: View {
    let choices: ExportChoices
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var actualSize = false
    /// Played or paused with the button; `nil`: as "Reduce motion" says.
    @State private var playing: Bool?

    private var isPlaying: Bool { playing ?? !reduceMotion }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Rectangle().fill(.quaternary)
                GIFPreviewView(preview: choices.preview, actualSize: actualSize, playing: isPlaying)
                    .opacity(choices.isMakingPreview ? 0.4 : 1)
                if choices.isMakingPreview {
                    Text("Making the preview…", comment: "The export sheet: while the GIF's preview is made")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .frame(width: 320, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: choices.isMakingPreview)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("GIF Preview", comment: "VoiceOver: the export sheet's preview of the GIF"))
            .accessibilityValue(
                isPlaying
                    ? Text("Playing", comment: "VoiceOver: the GIF's preview while it plays")
                    : Text("Paused"))
            .accessibilityAddTraits(.isImage)
            HStack(spacing: 8) {
                Toggle(isOn: $actualSize) {
                    Text("Actual Size", comment: "The export sheet: the GIF's preview 1:1 with the screen's pixels")
                }
                .toggleStyle(.button)
                if reduceMotion {
                    Button {
                        playing = !isPlaying
                    } label: {
                        Label(isPlaying ? LocalizedStringKey("Pause") : LocalizedStringKey("Play"), systemImage: isPlaying ? "pause.fill" : "play.fill")
                    }
                }
            }
        }
    }
}

/// The preview in an `NSImageView`, which plays the GIF, inside a scroll view: fitted to it, or 1:1 with the screen's
/// pixels and scrolled to the middle.
private struct GIFPreviewView: NSViewRepresentable {
    let preview: GIFPreviewImage?
    let actualSize: Bool
    let playing: Bool

    final class Coordinator {
        /// The `GIFPreviewImage.id` shown.
        var shown: Int?
        var wasActualSize = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let imageView = NSImageView()
        imageView.imageFrameStyle = .none
        imageView.imageAlignment = .alignCenter
        imageView.isEditable = false
        // The SwiftUI view around it is the accessibility element ("GIF Preview").
        imageView.setAccessibilityElement(false)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = imageView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let imageView = scroll.documentView as? NSImageView else { return }
        let coordinator = context.coordinator
        if coordinator.shown != preview?.id {
            coordinator.shown = preview?.id
            imageView.image = preview?.image
        }
        imageView.animates = playing
        if !playing, let rep = preview?.image.representations.first as? NSBitmapImageRep {
            // Paused, the first frame.
            rep.setProperty(.currentFrame, withValue: 0)
            imageView.needsDisplay = true
        }
        let box = scroll.contentSize
        if actualSize, let preview {
            // One pixel of the GIF on one pixel of the screen.
            let scale = scroll.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            let size = NSSize(width: preview.pixels.width / scale, height: preview.pixels.height / scale)
            preview.image.size = size
            imageView.imageScaling = .scaleNone
            imageView.autoresizingMask = []
            imageView.frame = NSRect(x: 0, y: 0, width: max(size.width, box.width), height: max(size.height, box.height))
            scroll.hasHorizontalScroller = size.width > box.width
            scroll.hasVerticalScroller = size.height > box.height
            if !coordinator.wasActualSize {
                let middle = NSPoint(x: (imageView.frame.width - box.width) / 2, y: (imageView.frame.height - box.height) / 2)
                scroll.contentView.scroll(to: middle)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        } else {
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.autoresizingMask = [.width, .height]
            imageView.frame = NSRect(origin: .zero, size: box)
            scroll.hasHorizontalScroller = false
            scroll.hasVerticalScroller = false
        }
        coordinator.wasActualSize = actualSize && preview != nil
    }
}
