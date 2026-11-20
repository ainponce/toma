// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import Foundation
import ImageAnalysis
import ProjectFormat
import ProjectJobs
import SwiftUI

/// The search of sensitive data (phase 2 design §7.2) as the editor runs it: one job per take of the document in the
/// project's analysis queue (`AnalysisJobKind.sensitiveScan(take:)`, plan 2c decision 6), its findings read from its
/// cache once it is done, the findings sheet, and "Blur N", one step `privacy.auto`. Also what the Privacy tab's card
/// changes of the selected block (its strength, its color, deleting it).
extension EditorModel {
    /// The takes the search looks at: each take the document's sequence shows, the project focused on it, in the order
    /// the sequence first shows them (`SensitiveScanJob.projects(of:shownBy:)`, phase 3 design §8.1): a take new in the
    /// sequence has a job of its own.
    var sensitiveScanProjects: [LoadedProject] {
        guard let document, let project = overlayProject else { return [] }
        return SensitiveScanJob.projects(of: project, shownBy: document)
    }

    /// "Find Sensitive Data": a job per take, at the end of the queue. One that waits or runs is not asked for twice; one
    /// with a cache that holds is done at once, without looking at a frame (`SensitiveScanJob.work`). Whether it asked
    /// for any.
    @discardableResult
    func findSensitiveData() -> Bool {
        let projects = sensitiveScanProjects
        guard canEdit, let document, let caches = panelSession?.caches, !projects.isEmpty else { return false }
        for project in projects {
            let work = SensitiveScanJob.work(project: project, document: document, caches: caches)
            let kind = AnalysisJobKind.sensitiveScan(take: project.take.id)
            Task { [jobs] in await jobs.enqueue(kind, work: work) }
        }
        return true
    }

    /// Cancel: the search's jobs leave the queue, or stop; nothing of them is written.
    func cancelSensitiveSearch() {
        let kinds = sensitiveScanProjects.map { AnalysisJobKind.sensitiveScan(take: $0.take.id) }
        Task { [jobs] in
            for kind in kinds { await jobs.cancel(kind) }
        }
    }

    /// What the search found in every take as the document shows it now, from the caches (`SensitiveScanJob.cached`),
    /// read off the main thread; `nil` when a take has no cache that holds.
    func cachedSensitiveFindings() async -> [PrivacyFinding]? {
        guard let document, let caches = panelSession?.caches else { return nil }
        let projects = sensitiveScanProjects
        guard !projects.isEmpty else { return nil }
        return await Task.detached(priority: .utility) { () -> [PrivacyFinding]? in
            var found: [PrivacyFinding] = []
            for project in projects {
                guard let result = SensitiveScanJob.cached(project: project, document: document, caches: caches) else { return nil }
                found += result.findings
            }
            return found
        }.value
    }

    /// The findings sheet over the window, for `findings` and the document as it is now.
    func showSensitiveFindings(_ findings: [PrivacyFinding]) {
        guard canEdit, let document, let window, window.attachedSheet == nil else { return }
        let rules = FindingsSheetRules(blocks: findings.map { $0.block(id: "p-00000000") }, document: document)
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        let close: @MainActor () -> Void = { [weak window, weak sheet] in
            guard let window, let sheet else { return }
            window.endSheet(sheet)
            // On the next turn, out of the button's action: the sheet's view goes with its window.
            Task { @MainActor in
                sheet.contentViewController = nil
                sheet.close()
            }
        }
        sheet.contentViewController = NSHostingController(
            rootView: SensitiveFindingsSheet(findings: findings, rules: rules, close: close) { [weak self] blocks in
                close()
                self?.blurFindings(blocks)
            })
        window.beginSheet(sheet)
    }

    /// "Blur N": the blocks of the checked findings, in one step (`privacy.auto`).
    func blurFindings(_ blocks: [PrivacyBlock]) {
        guard canEdit, let document, let step = PrivacyCommands.addAuto(document, blocks: blocks, makeID: Self.newID) else { return }
        perform(step)
    }

    // MARK: - The selected block's card

    /// The strength of block `id`, from the bar's 0 to 100: a drag is a gesture.
    func setPrivacyStrength(percent: Int, id: String) {
        guard let document, let step = PrivacyCommands.change(document, id: id, strength: Double(percent) / 100) else { return }
        if isGesturing { updateGesture(step) } else { perform(step) }
    }

    /// The colour of block `id`'s fill.
    func setPrivacyColor(_ color: RGBA, id: String) {
        guard canEdit, let document, let step = PrivacyCommands.change(document, id: id, color: color) else { return }
        perform(step)
    }

    /// "Delete Blur".
    func deletePrivacyBlock(_ id: String) {
        guard canEdit, let document, let step = PrivacyCommands.delete(document, ids: [id]) else { return }
        perform(step)
    }

    #if DEBUG
    /// `TOMA_SHOWCASE_SELECT=scan-running`, `scan-none`, `scan-found` or `scan-blurred`, with the Privacy tab: a search
    /// that runs (a job of the queue at 42 % that waits until it is cancelled); one that found nothing; seven findings,
    /// with their sheet; or those seven blurred, an email's block selected. All but the first write the take's cache as a
    /// scan would and search: the job finds it, as searching again does.
    func showcaseSensitiveSearch(_ variant: String) {
        guard let project = sensitiveScanProjects.first, let document, let caches = panelSession?.caches,
            let url = caches.scanFile(take: project.take.id, algorithm: SensitiveScan.algorithm)
        else { return }
        let take = project.take.id
        if variant == "scan-running" {
            Task { [jobs] in
                await jobs.enqueue(.sensitiveScan(take: take)) { progress in
                    progress.report(0.42)
                    while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)) }
                    throw CancellationError()
                }
            }
            return
        }
        let findings = variant == "scan-none" ? [] : Self.showcaseFindings(take: take, start: project.take.tracks.first?.segments.first?.startHostTime)
        Task {
            let written = await Task.detached(priority: .utility) {
                let result = ScanResult(
                    algorithm: SensitiveScan.algorithm, findings: findings,
                    samples: SensitiveScan.fingerprint(project: project, document: document),
                    segments: SensitiveScanJob.segmentNames(of: project.take, in: project.package), take: take,
                    version: ScanResult.currentVersion)
                return (try? ProjectJSON.encoder().encode(result)).map { ProjectCaches.writeAnalysis($0, to: url) } ?? false
            }.value
            guard written else { return }
            findSensitiveData()
            guard !findings.isEmpty else { return }
            try? await Task.sleep(for: .seconds(1))
            guard variant == "scan-blurred" else { return showSensitiveFindings(findings) }
            // `scan-blurred`: "Blur 7", and the card of the first email's block.
            blurFindings(findings.map { $0.block(id: "p-00000000") })
            if let block = self.document?.privacy.blocks.first(where: { $0.origin == .email }) {
                selectPrivacyBlock(block.id, showingIt: true)
            }
        }
    }

    /// Seven made-up findings of every kind, masked as the scan masks them, from `start` on.
    private static func showcaseFindings(take: String, start: HostTime?) -> [PrivacyFinding] {
        guard let start else { return [] }
        let made: [(SensitiveKind, String, Double, Double, NormalizedRect)] = [
            (.email, "an•••@g•••.com", 0.5, 4, NormalizedRect(x: 0.12, y: 0.18, width: 0.24, height: 0.04)),
            (.email, "lu•••@t•••.dev", 6, 9.5, NormalizedRect(x: 0.12, y: 0.42, width: 0.22, height: 0.04)),
            (.phone, "•••• 01", 2, 5, NormalizedRect(x: 0.6, y: 0.3, width: 0.16, height: 0.04)),
            (.card, "•••• 4242", 3.25, 7, NormalizedRect(x: 0.4, y: 0.55, width: 0.2, height: 0.05)),
            (.secret, "sk-•••", 1, 11, NormalizedRect(x: 0.1, y: 0.7, width: 0.36, height: 0.04)),
            (.token, "ghp•••", 8, 10, NormalizedRect(x: 0.1, y: 0.76, width: 0.3, height: 0.04)),
            (.face, "", 0, 12, NormalizedRect(x: 0.78, y: 0.66, width: 0.12, height: 0.2)),
        ]
        return made.map { kind, masked, from, to, rect in
            PrivacyFinding(
                kind: kind, masked: masked, take: take, start: start.adding(seconds: from), end: start.adding(seconds: to),
                keys: [RectKey(t: start.adding(seconds: from), rect: rect)])
        }
    }
    #endif
}

/// The search of sensitive data as the Privacy tab shows it: from the states of its jobs in the project's queue and,
/// once they are done, the findings of their caches. Made by the tab and followed while it shows (`follow(_:)`): the
/// jobs go on without it, and the tab shown again finds them where they are.
@MainActor @Observable
final class SensitiveSearch {
    enum Phase: Equatable {
        /// Never asked for, cancelled, or what it found no longer holds for the document.
        case idle
        /// In the queue behind another analysis (`nil`), or running, from 0 to 1.
        case searching(Double?)
        /// What it found, in the order of the takes and each take's by start; maybe nothing.
        case found([PrivacyFinding])
        /// It could not, for this reason: searching again may work.
        case failed(JobProblem)
        /// It cannot on this Mac.
        case unavailable(JobProblem)
    }

    private(set) var phase = Phase.idle
    /// Whether this Mac recognizes text (`VisionRecognizer.isAvailable`), as found when the tab first showed.
    private(set) var canRecognize = true

    /// Follows `model`'s search until the task is cancelled (the tab went): at once what its caches hold, then each
    /// change of its jobs' states.
    func follow(_ model: EditorModel) async {
        canRecognize = await Task.detached(priority: .utility) { VisionRecognizer.isAvailable }.value
        let kinds = model.sensitiveScanProjects.map { AnalysisJobKind.sensitiveScan(take: $0.take.id) }
        guard !kinds.isEmpty else { return }
        for await states in await model.jobs.updates() {
            // The queue says every job's changes: only the search's own count.
            let mine = kinds.map { states[$0] }
            guard mine != lastStates else { continue }
            lastStates = mine
            await settle(mine, model: model)
        }
    }

    /// Shows the search started, before the queue says it. What the queue says next is read even if it ends as it was
    /// (a search done again with its cache can be done again before it is read).
    func started() {
        phase = .searching(nil)
        lastStates = nil
    }

    /// The states of the search's jobs last settled.
    @ObservationIgnored private var lastStates: [JobState?]?

    private func settle(_ states: [JobState?], model: EditorModel) async {
        var running: [Double] = []
        var waiting = false
        for state in states {
            switch state {
            case .waiting?: waiting = true
            case let .running(progress)?: running.append(progress)
            case let .unavailable(problem)?:
                phase = .unavailable(problem)
                return
            case let .failed(problem)?:
                phase = .failed(problem)
                return
            case .done?, nil: break
            }
        }
        if waiting || !running.isEmpty {
            // One take: its own; several: how far the whole is, a take waiting at 0 and one done at 1.
            let done = states.filter { $0 == .done }.count
            phase = running.isEmpty ? .searching(nil) : .searching((running.reduce(0, +) + Double(done)) / Double(states.count))
            return
        }
        // All done, or never asked for (a scan of another session may hold), or cancelled.
        if states.contains(where: { $0 != nil }), case .searching = phase { phase = .searching(1) }
        let found = await model.cachedSensitiveFindings()
        phase = found.map(Phase.found) ?? .idle
    }
}
