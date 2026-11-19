// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Speech
import Synchronization

/// Whether the model of a language is on this Mac.
public enum LanguageModelStatus: Equatable, Sendable {
    case installed
    /// The system can download it (`SpeechLanguages.download`).
    case downloadable
    case downloading
    /// No model transcribes it on this Mac, or the Mac cannot transcribe (macOS 15, `SpeechTranscriber` unavailable).
    case unsupported
}

/// The languages `speechTranscriber-1` transcribes (phase 2 design §5.1, plan decision 2), always as BCP 47 (`es-MX`;
/// the SDK lists `es_MX`). Before macOS 26 nothing calls Speech: the lists are empty and every language unsupported.
public enum SpeechLanguages {
    /// `Transcript.engine` of what `SpeechTranscriberEngine` hears.
    public static let engineID = "speechTranscriber-1"

    /// Whether this macOS has `SpeechTranscriber` (macOS 26).
    public static var isSupportedOS: Bool {
        if #available(macOS 26, *) { true } else { false }
    }

    /// Whether this Mac can transcribe: macOS 26 and `SpeechTranscriber.isAvailable`.
    public static func isAvailable() -> Bool {
        if #available(macOS 26, *) { SpeechTranscriber.isAvailable } else { false }
    }

    /// The languages `SpeechTranscriber` transcribes, in BCP 47, sorted.
    public static func supported() async -> [String] {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else { return [] }
        return identifiers(await SpeechTranscriber.supportedLocales)
    }

    /// The languages whose model is on this Mac, in BCP 47, sorted.
    public static func installed() async -> [String] {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable else { return [] }
        return identifiers(await SpeechTranscriber.installedLocales)
    }

    /// The language to transcribe in when none was chosen: the first of `preferred` (the Mac's languages, in order)
    /// that `equivalent` takes to one of `supported`; without one, `en-US` if it is supported; without it, the first
    /// of `supported`; `nil` when nothing is supported.
    public static func defaultLanguage(
        preferred: [String], supported: [String], equivalent: (String) async -> String?
    ) async -> String? {
        let supported = supported.map(bcp47)
        guard let first = supported.first else { return nil }
        for language in preferred {
            if let match = await equivalent(language).map(bcp47), supported.contains(match) { return match }
        }
        return supported.contains("en-US") ? "en-US" : first
    }

    /// `defaultLanguage(preferred:supported:equivalent:)` with the Mac's preferred languages and what
    /// `SpeechTranscriber.supportedLocale(equivalentTo:)` takes them to (`es-419` → `es-MX`).
    public static func defaultLanguage() async -> String? {
        guard #available(macOS 26, *) else { return nil }
        return await defaultLanguage(preferred: Locale.preferredLanguages, supported: supported()) { language in
            await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language))?.identifier(.bcp47)
        }
    }

    /// Whether the model of `language` is on this Mac, can be downloaded or is being downloaded.
    ///
    /// Installed is what `SpeechTranscriber.installedLocales` lists: `AssetInventory.status(forModules:)` says
    /// `.supported` for a model that is on the Mac until this app reserves its language (seen on macOS 26.6 from a
    /// process without a bundle), and the model transcribes all the same.
    public static func status(of language: String) async -> LanguageModelStatus {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language))
        else { return .unsupported }
        if await isInstalled(locale) { return .installed }
        switch await AssetInventory.status(forModules: [SpeechTranscriberEngine.module(for: locale)]) {
        case .installed: return .installed
        case .downloading: return .downloading
        case .supported: return .downloadable
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Downloads and installs the model of `language` (`AssetInventory`), reporting its progress from 0 to 1, never
    /// down. Only the user's "Download the Language" calls it. Returns at once when it is already installed.
    /// - Throws: `TranscriptionError.needsMacOS26`, `.notOnThisMac`, `.engine` (a language it does not transcribe, or
    ///   what the download said); `CancellationError` if the task is cancelled (the download is cancelled with it).
    public static func download(_ language: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard #available(macOS 26, *) else { throw TranscriptionError.needsMacOS26 }
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.notOnThisMac }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw TranscriptionError.engine("SpeechTranscriber does not transcribe \(language)")
        }
        let request: AssetInstallationRequest?
        do {
            request = try await AssetInventory.assetInstallationRequest(supporting: [SpeechTranscriberEngine.module(for: locale)])
        } catch {
            throw TranscriptionError.engine(String(describing: error))
        }
        guard let request else {
            progress(1)
            return
        }
        do {
            try await install(request.progress, progress: progress) { try await request.downloadAndInstall() }
        } catch {
            throw error is CancellationError || Task.isCancelled ? CancellationError() : TranscriptionError.engine(String(describing: error))
        }
    }

    /// Runs `run`, which downloads, reporting `observed` as it moves and 1 once it returned; cancelling the task
    /// cancels `observed`, which stops the download.
    static func install(
        _ observed: Progress, progress: @escaping @Sendable (Double) -> Void, _ run: () async throws -> Void
    ) async throws {
        let reporter = ProgressReporter(progress)
        let observation = observed.observe(\.fractionCompleted, options: [.initial, .new]) { observed, _ in
            reporter.report(observed.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await withTaskCancellationHandler {
            try await run()
        } onCancel: {
            observed.cancel()
        }
        try Task.checkCancellation()
        reporter.report(1)
    }

    /// Whether `SpeechTranscriber.installedLocales` lists `locale`.
    @available(macOS 26, *)
    static func isInstalled(_ locale: Locale) async -> Bool {
        let identifier = locale.identifier(.bcp47)
        return await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == identifier }
    }

    /// `identifier` as BCP 47: `es_MX` and `es-MX` are `es-MX`.
    static func bcp47(_ identifier: String) -> String {
        Locale(identifier: identifier).identifier(.bcp47)
    }

    private static func identifiers(_ locales: [Locale]) -> [String] {
        Array(Set(locales.map { $0.identifier(.bcp47) })).sorted()
    }
}

/// Hands on a progress from 0 to 1 that only goes up, from any thread, in order.
private final class ProgressReporter: Sendable {
    private let last = Mutex(-1.0)
    private let progress: @Sendable (Double) -> Void

    init(_ progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func report(_ value: Double) {
        let value = min(1, max(0, value.isFinite ? value : 0))
        // Under the lock, so two threads never hand theirs on out of order.
        last.withLock { last in
            guard value > last else { return }
            last = value
            progress(value)
        }
    }
}
