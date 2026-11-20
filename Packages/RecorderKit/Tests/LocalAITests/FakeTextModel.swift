// SPDX-License-Identifier: GPL-3.0-or-later
import Synchronization

@testable import LocalAI

/// A `TextModel` that answers by a script and keeps what it was asked, so the suggesters are tested without the system
/// model. Its tokens are `2 × words + 2`, its context `contextSize`.
final class FakeTextModel: TextModel {
    struct Request: Equatable, Sendable {
        /// `nil` for chapters.
        var kind: InfoKind?
        var instructions: String
        var prompt: String
        var variation: Int
    }

    typealias ChapterAnswer = @Sendable (String) -> Result<[ProposedChapter], AIError>
    typealias TextAnswer = @Sendable (InfoKind, String) -> Result<String, AIError>

    let contextSize: Int
    private let availabilityAnswer: @Sendable (String) -> AIAvailability
    /// The answer to the n-th chapters request; the last one answers every request after it. Empty: no chapters.
    private let chapterScript: [ChapterAnswer]
    /// The same for the texts.
    private let textScript: [TextAnswer]
    private let asked = Mutex<[Request]>([])

    init(
        contextSize: Int = 4096,
        availability: @escaping @Sendable (String) -> AIAvailability = { _ in .available },
        chapters: [ChapterAnswer] = [],
        texts: [TextAnswer] = []
    ) {
        self.contextSize = contextSize
        self.availabilityAnswer = availability
        self.chapterScript = chapters
        self.textScript = texts
    }

    var requests: [Request] { asked.withLock { $0 } }

    func availability(language: String) -> AIAvailability { availabilityAnswer(language) }

    func tokenCount(_ text: String) async -> Int { Self.tokens(text) }

    static func tokens(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count * 2 + 2 }

    func chapters(instructions: String, prompt: String) async throws -> [ProposedChapter] {
        let number = record(Request(kind: nil, instructions: instructions, prompt: prompt, variation: 0))
        guard !chapterScript.isEmpty else { return [] }
        return try chapterScript[min(number, chapterScript.count - 1)](prompt).get()
    }

    func text(_ kind: InfoKind, instructions: String, prompt: String, variation: Int) async throws -> String {
        let number = record(Request(kind: kind, instructions: instructions, prompt: prompt, variation: variation))
        guard !textScript.isEmpty else { return "" }
        return try textScript[min(number, textScript.count - 1)](kind, prompt).get()
    }

    /// Keeps `request`; how many of its sort (chapters or texts) came before it.
    private func record(_ request: Request) -> Int {
        asked.withLock { requests in
            let before = requests.count { ($0.kind == nil) == (request.kind == nil) }
            requests.append(request)
            return before
        }
    }

    /// The numbers of the lines of a chapters prompt (`[12 @1:05] …`), in order.
    static func lineNumbers(in prompt: String) -> [Int] {
        prompt.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("["), let space = line.firstIndex(of: " ") else { return nil }
            return Int(line[line.index(after: line.startIndex)..<space])
        }
    }

    /// An answer that proposes the first line of each part, titled `title` (or "Parte <its number>").
    static func firstLine(_ title: String? = nil) -> ChapterAnswer {
        { prompt in
            .success(lineNumbers(in: prompt).prefix(1).map { ProposedChapter(title: title ?? "Parte \($0)", firstWordIndex: $0) })
        }
    }
}

/// What a `@Sendable` closure saw, in order.
final class Collected<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])
    func append(_ value: Value) { values.withLock { $0.append(value) } }
    var all: [Value] { values.withLock { $0 } }
}
