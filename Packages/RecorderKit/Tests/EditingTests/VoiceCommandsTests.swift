// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

@Test func syncIsSteppedAndClamped() throws {
    let doc = VoiceFixture.document()
    let stepped = try #require(VoiceCommands.setSyncOffset(doc, milliseconds: 17))
    #expect(stepped.label == .cameraSync)
    #expect(try VoiceFixture.applying(stepped, to: doc).camera.syncOffset == 20_000_000)
    let low = try #require(VoiceCommands.setSyncOffset(doc, milliseconds: -305))
    #expect(try VoiceFixture.applying(low, to: doc).camera.syncOffset == -300_000_000)
    let high = try #require(VoiceCommands.setSyncOffset(doc, milliseconds: 1000))
    #expect(try VoiceFixture.applying(high, to: doc).camera.syncOffset == 300_000_000)
    // The legacy value, or one that rounds to what it already is: nothing.
    #expect(VoiceCommands.setSyncOffset(doc, milliseconds: 0) == nil)
    #expect(VoiceCommands.setSyncOffset(doc, milliseconds: 4) == nil)
    let edited = try VoiceFixture.applying(stepped, to: doc)
    #expect(VoiceCommands.setSyncOffset(edited, milliseconds: 20) == nil)
}

@Test func cleanupOfAnUnlistedTrackAddsIt() throws {
    var doc = VoiceFixture.document()
    doc.audio.tracks = [:]
    let step = try #require(VoiceCommands.setCleanup(doc, track: "take-001/mic-1", .gentle))
    #expect(step.label == .audioCleanup)
    let edited = try VoiceFixture.applying(step, to: doc)
    #expect(edited.audio.tracks["take-001/mic-1"] == TrackGain(gain: 1, muted: false, cleanup: 0.6))
    // Off for a track that is not listed is nothing to write.
    #expect(VoiceCommands.setCleanup(doc, track: "take-001/mic-1", .off) == nil)
}

@Test func cleanupOfAListedTrackKeepsItsGain() throws {
    var doc = VoiceFixture.document()
    doc.audio.tracks = ["take-001/mic-1": TrackGain(gain: 1.5, muted: true)]
    let step = try #require(VoiceCommands.setCleanup(doc, track: "take-001/mic-1", .strong))
    #expect(try VoiceFixture.applying(step, to: doc).audio.tracks["take-001/mic-1"] == TrackGain(gain: 1.5, muted: true, cleanup: 1))
    #expect(VoiceCommands.setCleanup(doc, track: "take-001/mic-1", .off) == nil)
}

@Test func cleanupLevelsAreTheDesignOnes() {
    #expect(CleanupLevel.allCases.map(\.rawValue) == [0, 0.6, 1])
    #expect(CleanupLevel(cleanup: 0.55) == .gentle)
    #expect(CleanupLevel(cleanup: 0.9) == .strong)
    #expect(CleanupLevel(cleanup: 0.1) == .off)
    #expect(CleanupLevel(cleanup: 0) == .off)
    #expect(CleanupLevel(cleanup: .nan) == .off)
}

@Test func presetResetsTheHighlight() throws {
    let doc = VoiceFixture.document()
    #expect(doc.captions.style.preset == .bold && doc.captions.style.highlight)
    let classic = try #require(VoiceCommands.setCaptionPreset(doc, .classic))
    #expect(classic.label == .captionsStyle)
    let edited = try VoiceFixture.applying(classic, to: doc)
    #expect(edited.captions.style.preset == .classic)
    #expect(!edited.captions.style.highlight)
    let bold = try #require(VoiceCommands.setCaptionPreset(edited, .bold))
    #expect(bold.changes.count == 2)
    let back = try VoiceFixture.applying(bold, to: edited)
    #expect(back.captions.style.preset == .bold && back.captions.style.highlight)
    #expect(VoiceCommands.setCaptionPreset(doc, .bold) == nil)
    // From Classic to Minimal the highlight was off already: one change.
    let minimal = try #require(VoiceCommands.setCaptionPreset(edited, .minimal))
    #expect(minimal.changes.count == 1)
}

@Test func styleAndShowAreOneSetEach() throws {
    let doc = VoiceFixture.document()
    var style = doc.captions.style
    style.size = .large
    style.uppercase = true
    let step = try #require(VoiceCommands.setCaptionStyle(doc, style))
    #expect(step.label == .captionsStyle)
    #expect(step.target == "/captions/style")
    #expect(step.changes.count == 1)
    #expect(try VoiceFixture.applying(step, to: doc).captions.style == style)
    #expect(VoiceCommands.setCaptionStyle(doc, doc.captions.style) == nil)

    let show = try #require(VoiceCommands.setCaptionsShow(doc, true))
    #expect(show.label == .captionsShow)
    #expect(show.target == "/captions/show")
    #expect(show.changes.count == 1)
    #expect(try VoiceFixture.applying(show, to: doc).captions.show)
    #expect(VoiceCommands.setCaptionsShow(doc, false) == nil)
}

@Test func normalizeIsOneSet() throws {
    let doc = VoiceFixture.document()
    let step = try #require(VoiceCommands.setNormalize(doc, true))
    #expect(step.label == .audioNormalize)
    #expect(try VoiceFixture.applying(step, to: doc).audio.normalize)
    #expect(VoiceCommands.setNormalize(doc, false) == nil)
}
