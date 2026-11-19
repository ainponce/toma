// SPDX-License-Identifier: GPL-3.0-or-later

/// The words spoken in the project, in source time (phase 2 design §5.1 and §8): `EditDocument.transcript`, `nil` until
/// the first transcription. Each take's first microphone track (or, without one, its first system audio track) is
/// transcribed whole, so the words survive cuts and speeds. Transcribing again replaces it whole.
public struct Transcript: Codable, Equatable, Sendable {
    /// The language it was transcribed in, as BCP 47 (`es-AR`, `en-US`).
    public var language: String
    /// The engine, with its version (`speechTranscriber-1`).
    public var engine: String
    /// One for each take transcribed. Inserted and removed (`EditCollection.transcriptTakes`), never replaced: it has no
    /// `id` (plan decision 7).
    public var takes: [TranscriptTake]

    public init(language: String, engine: String, takes: [TranscriptTake]) {
        self.language = language
        self.engine = engine
        self.takes = takes
    }
}

/// The words of one audio track of one take, in order.
public struct TranscriptTake: Codable, Equatable, Sendable {
    public var take: String
    public var track: String
    /// A word is corrected by its pointer (`/transcript/takes/<i>/words/<j>/text`).
    public var words: [TranscriptWord]

    public init(take: String, track: String, words: [TranscriptWord]) {
        self.take = take
        self.track = track
        self.words = words
    }
}

/// One word, with the punctuation that touches it, over the source times `[start, end)` of its take.
///
/// `breakBefore` is left out of the JSON when it is `false`, as almost every word has it (a transcription has thousands
/// of words; plan decision 5): a word that stops starting a caption is set whole, or its `breakBefore` taken away with a
/// `set` to `null` (plan decision 4). A `false` written by hand reads as `false`.
public struct TranscriptWord: Codable, Equatable, Sendable {
    public var start: HostTime
    /// Excluded.
    public var end: HostTime
    public var text: String
    /// Whether a caption starts at this word, as the user asked ("Start a Caption Here").
    public var breakBefore: Bool

    public init(start: HostTime, end: HostTime, text: String, breakBefore: Bool = false) {
        self.start = start
        self.end = end
        self.text = text
        self.breakBefore = breakBefore
    }

    private enum CodingKeys: String, CodingKey {
        case start, end, text, breakBefore
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            start: try container.decode(HostTime.self, forKey: .start),
            end: try container.decode(HostTime.self, forKey: .end),
            text: try container.decode(String.self, forKey: .text),
            breakBefore: try container.decodeIfPresent(Bool.self, forKey: .breakBefore) ?? false)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(text, forKey: .text)
        if breakBefore {
            try container.encode(true, forKey: .breakBefore)
        }
    }
}
