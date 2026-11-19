// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppSupport
import Observation
import SwiftUI

/// The system's microphone mode (Standard, Voice Isolation, Wide Spectrum), under the chosen microphone, with a button
/// that opens the system's picker. It is the system's mode, not Toma's: nothing here changes a take or its format. It
/// is enabled while the panel has the microphone open for its meter (`preview.isListening`).
struct MicrophoneModeRow: View {
    let preview: MicrophoneLevelPreview
    @State private var mode = MicrophoneModeWatcher()

    var body: some View {
        // "Mode: Voice Isolation" and the button may not fit on one line in Spanish: then the button goes below.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { modeText; Spacer(minLength: 0); changeButton }
            VStack(alignment: .leading, spacing: 6) { modeText; changeButton }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Microphone Mode"))
        .onAppear { mode.start() }
        .onDisappear { mode.stop() }
    }

    private var modeText: some View {
        Text("Mode: \(name)")
            .font(.system(size: 11.5))
            .lineLimit(1)
            .fixedSize()
            .opacity(preview.isListening ? 0.8 : 0.45)
    }

    private var changeButton: some View {
        Button {
            AVCaptureDevice.showSystemUserInterface(.microphoneModes)
        } label: {
            Text("Change…", comment: "Opens the system's picker of microphone modes")
                .font(.system(size: 11.5))
        }
        .buttonStyle(GlassButtonStyle())
        .controlSize(.small)
        .fixedSize()
        .disabled(!preview.isListening)
        // A disabled control shows no help: it goes on a container outside.
        .contentShape(Rectangle())
        .help(preview.isListening ? "" : String(localized: "Shown while the microphone is on."))
    }

    private var name: String {
        switch mode.kind {
        case .standard: String(localized: "Standard", comment: "Microphone mode of macOS")
        case .voiceIsolation: String(localized: "Voice Isolation", comment: "Microphone mode of macOS")
        case .wideSpectrum: String(localized: "Wide Spectrum", comment: "Microphone mode of macOS")
        }
    }
}

/// The active microphone mode, by KVO on the class (`AVCaptureDevice.activeMicrophoneMode`), kept on the main thread.
@MainActor @Observable
private final class MicrophoneModeWatcher {
    private(set) var kind = MicrophoneModeKind(AVCaptureDevice.activeMicrophoneMode)
    @ObservationIgnored private var observer: Observer?

    func start() {
        kind = MicrophoneModeKind(AVCaptureDevice.activeMicrophoneMode)
        guard observer == nil else { return }
        let observer = Observer { [weak self] in
            Task { @MainActor in self?.kind = MicrophoneModeKind(AVCaptureDevice.activeMicrophoneMode) }
        }
        (AVCaptureDevice.self as AnyObject).addObserver(
            observer, forKeyPath: "activeMicrophoneMode", options: [.new], context: nil)
        self.observer = observer
    }

    func stop() {
        guard let observer else { return }
        (AVCaptureDevice.self as AnyObject).removeObserver(observer, forKeyPath: "activeMicrophoneMode")
        self.observer = nil
    }

    private final class Observer: NSObject, @unchecked Sendable {
        let changed: @Sendable () -> Void
        init(_ changed: @escaping @Sendable () -> Void) { self.changed = changed }
        override func observeValue(
            forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
            context: UnsafeMutableRawPointer?
        ) { changed() }
    }
}
