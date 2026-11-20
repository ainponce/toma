// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Darwin
import Export
import Foundation

/// `recorder-dev music [--out <folder>] [--theme <id>]`: renders the themes of the music library (`music-1`) to
/// `<id>.caf`, the bytes the app's cache holds as `<id>-<fingerprint>.caf`, and prints how long each took and what it
/// measures (plan decision 5).
struct MusicRender: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "music",
        abstract: "Renders the themes of the music library to <id>.caf and prints their measures.",
        discussion: """
            Renders every theme of music-1 (calm, focus, drive, piano, pulse, breeze), or only --theme, with \
            MusicSynth.render and writes it to <out>/<id>.caf (MusicFile: the bytes the app's cache holds as \
            <id>-<fingerprint>.caf), replacing what is there. Prints a line per theme: its fingerprint, the seconds it took and how many times faster than real time, its \
            integrated loudness (LUFS), its peak (dBFS), its quietest 50 ms (dBFS), the correlation of its sides, its \
            energy under 30 Hz and over 16 kHz (dB of the total), and its seam (the step from its last frame to its \
            first next to the largest step inside it, and the level of its first 50 ms over its last 50 ms). A theme \
            that is still a placeholder says so. Build with -c release to time it as the app does.
            """
    )

    @Option(help: "The folder to write <id>.caf to (made if missing).")
    var out = "."

    @Option(help: "Only this theme: calm, focus, drive, piano, pulse or breeze.")
    var theme: String?

    func validate() throws {
        if let theme, !MusicThemes.ids.contains(theme) {
            throw ValidationError("--theme is one of \(MusicThemes.ids.joined(separator: ", ")).")
        }
    }

    func run() async throws {
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for id in theme.map({ [$0] }) ?? MusicThemes.ids {
            guard let score = MusicThemes.score(id) else { continue }
            let clock = ContinuousClock()
            let started = clock.now
            let samples = MusicSynth.render(score)
            let elapsed = clock.now - started
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let url = folder.appending(path: "\(id).caf", directoryHint: .notDirectory)
            try MusicFile.write(interleaved: samples, to: url)
            let duration = Double(samples.count / 2) / Double(MusicSynth.sampleRate)
            let seam = MusicMetrics.seam(samples)
            func decibels(_ x: Float) -> String { String(format: "%.2f", 20 * log10(Double(max(x, 1e-12)))) }
            let fields = [
                id + (score.isPlaceholder ? " (placeholder)" : ""),
                score.fingerprint,
                String(format: "%.2f s", seconds),
                String(format: "%.1f× real time", duration / max(seconds, 1e-9)),
                MusicMetrics.loudness(samples).map { String(format: "%.2f LUFS", $0) } ?? "silent",
                "peak \(decibels(MusicMetrics.peak(samples))) dBFS",
                String(format: "quietest 50 ms %.1f dBFS", MusicMetrics.quietestWindow(samples)),
                String(format: "correlation %.3f", MusicMetrics.correlation(samples)),
                String(format: "under 30 Hz %.1f dB", MusicMetrics.band(samples, below: 30)),
                String(format: "over 16 kHz %.1f dB", MusicMetrics.band(samples, above: 16_000)),
                String(format: "seam %.5f (inside %.5f), %.2f dB across", seam.jump, seam.largestInside, seam.windowsAcross),
            ]
            print(fields.joined(separator: "  "))
            print(url.path)
        }
    }
}
