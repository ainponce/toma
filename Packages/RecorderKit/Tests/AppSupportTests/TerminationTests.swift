// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import Testing

@Test(arguments: [false, true])
func quittingClosesATakeAndAsksBeforeCancellingAnExport(poweringOff: Bool) {
    #expect(TerminationDecision.decide(isRecording: false, isExporting: false, isPoweringOff: poweringOff, isCopying: false) == .now)
    #expect(TerminationDecision.decide(isRecording: true, isExporting: false, isPoweringOff: poweringOff, isCopying: false) == .closeTakeFirst)
    if poweringOff {
        // Nobody to ask while logging out or shutting down: the export is cancelled, its partial file removed.
        #expect(TerminationDecision.decide(isRecording: false, isExporting: true, isPoweringOff: true, isCopying: false) == .cancelExportFirst(alsoClosingTake: false))
        #expect(TerminationDecision.decide(isRecording: true, isExporting: true, isPoweringOff: true, isCopying: false) == .cancelExportFirst(alsoClosingTake: true))
    } else {
        #expect(TerminationDecision.decide(isRecording: false, isExporting: true, isPoweringOff: false, isCopying: false) == .confirmCancelExport(alsoClosingTake: false))
        #expect(TerminationDecision.decide(isRecording: true, isExporting: true, isPoweringOff: false, isCopying: false) == .confirmCancelExport(alsoClosingTake: true))
    }
}

/// A copy of the library under way is never answered `.now`: it is never left half done (design §6.8). With a take or an
/// export too, their own order holds, and the copies are waited for last.
@Test(arguments: [false, true])
func aCopyInProgressIsNeverQuitNow(poweringOff: Bool) {
    #expect(TerminationDecision.decide(isRecording: false, isExporting: false, isPoweringOff: poweringOff, isCopying: true) == .finishCopiesFirst)
    #expect(TerminationDecision.decide(isRecording: true, isExporting: false, isPoweringOff: poweringOff, isCopying: true) == .closeTakeFirst)
    let export = TerminationDecision.decide(isRecording: false, isExporting: true, isPoweringOff: poweringOff, isCopying: true)
    #expect(export == (poweringOff ? .cancelExportFirst(alsoClosingTake: false) : .confirmCancelExport(alsoClosingTake: false)))
}

@Test func recoveredProjectsOpenAFewAndReloadTheOpenOnes() {
    let urls = (1...5).map { URL(fileURLWithPath: "/Users/me/Movies/Toma/Recording \($0).toma", isDirectory: true) }
    let (reload, open) = RecoveredProjects.editors(recovered: urls, openEditors: [urls[3]])
    #expect(reload == [urls[3]])
    #expect(open == [urls[0], urls[1], urls[2]])
    #expect(open.count == RecoveredProjects.maximumOpened)

    let two = RecoveredProjects.editors(recovered: [urls[0], urls[1], urls[0]], openEditors: [])
    #expect(two.reload.isEmpty && two.open == [urls[0], urls[1]])
    // The same package by another spelling of its path is the same editor.
    let spelled = URL(fileURLWithPath: "/Users/me/Movies/Toma/../Toma/Recording 1.toma", isDirectory: true)
    #expect(RecoveredProjects.editors(recovered: [spelled], openEditors: [urls[0]]).reload == [urls[0]])
}
