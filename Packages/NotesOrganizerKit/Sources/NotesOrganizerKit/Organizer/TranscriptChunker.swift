import Foundation

/// Splits long transcript text into chunks that fit the model's context
/// window, one model call per chunk. Pure and synchronous — no model calls
/// happen here.
///
/// Strategy: paragraphs (blank-line separated) are packed greedily up to
/// `budget.targetTokensPerChunk`. A paragraph that alone exceeds
/// `budget.hardCeilingTokens` is split on sentence boundaries instead, and
/// a single sentence that still exceeds the hard ceiling (no punctuation to
/// split on) is split on a fixed character budget so the chunker always
/// terminates. A one-sentence overlap is added at the start of every chunk
/// after the first, so the model sees a little context from what came
/// before it.
struct TranscriptChunker {
    struct Budget: Sendable {
        let targetTokensPerChunk: Int
        let hardCeilingTokens: Int

        static let `default` = Budget(targetTokensPerChunk: 1000, hardCeilingTokens: 1400)

        /// Used for the single re-chunk after the model rejects a chunk the
        /// token estimate said would fit. Cutting the ceiling roughly in
        /// half buys enough room for whatever the estimate under-counted.
        static let reduced = Budget(targetTokensPerChunk: 500, hardCeilingTokens: 700)
    }

    private let tokenEstimator: TokenEstimating
    private let budget: Budget

    init(tokenEstimator: TokenEstimating = HeuristicTokenEstimator(), budget: Budget = .default) {
        self.tokenEstimator = tokenEstimator
        self.budget = budget
    }

    func chunk(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if tokenEstimator.tokenCount(trimmed) <= budget.hardCeilingTokens {
            return [trimmed]
        }

        var chunks: [String] = []
        var current = ""

        func flushCurrent() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                chunks.append(piece)
            }
            current = ""
        }

        for paragraph in paragraphs(in: trimmed) {
            if tokenEstimator.tokenCount(paragraph) > budget.hardCeilingTokens {
                flushCurrent()
                chunks.append(contentsOf: splitOversizedParagraph(paragraph))
                continue
            }

            if current.isEmpty {
                current = paragraph
                continue
            }

            let candidate = current + "\n\n" + paragraph
            if tokenEstimator.tokenCount(candidate) <= budget.targetTokensPerChunk {
                current = candidate
            } else {
                flushCurrent()
                current = paragraph
            }
        }
        flushCurrent()

        return withSentenceOverlap(chunks)
    }

    // MARK: - Paragraph splitting

    private func paragraphs(in text: String) -> [String] {
        text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Sentence splitting (oversized paragraphs)

    private func splitOversizedParagraph(_ paragraph: String) -> [String] {
        let sentenceList = sentences(in: paragraph)
        guard !sentenceList.isEmpty else {
            return hardCharacterSplit(paragraph)
        }

        var chunks: [String] = []
        var current = ""

        func flushCurrent() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                chunks.append(piece)
            }
            current = ""
        }

        for sentence in sentenceList {
            if tokenEstimator.tokenCount(sentence) > budget.hardCeilingTokens {
                flushCurrent()
                chunks.append(contentsOf: hardCharacterSplit(sentence))
                continue
            }

            if current.isEmpty {
                current = sentence
                continue
            }

            let candidate = current + " " + sentence
            if tokenEstimator.tokenCount(candidate) <= budget.targetTokensPerChunk {
                current = candidate
            } else {
                flushCurrent()
                current = sentence
            }
        }
        flushCurrent()

        return chunks
    }

    private func sentences(in text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences, .localized]) { substring, _, _, _ in
            guard let substring else { return }
            let trimmed = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.append(trimmed)
            }
        }
        return result
    }

    // MARK: - Degenerate fallback: no sentence/paragraph boundaries at all

    /// Splits `text` at a fixed character budget derived from the injected
    /// `tokenEstimator`, growing each piece one character at a time until it
    /// would exceed the target. Always advances by at least one character,
    /// so this terminates even for text with no whitespace or punctuation.
    private func hardCharacterSplit(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        var pieces: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            var end = text.index(after: start)
            while end < text.endIndex {
                let next = text.index(after: end)
                let candidate = String(text[start..<next])
                if tokenEstimator.tokenCount(candidate) > budget.targetTokensPerChunk {
                    break
                }
                end = next
            }
            let piece = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                pieces.append(piece)
            }
            start = end
        }
        return pieces
    }

    // MARK: - Overlap

    private func withSentenceOverlap(_ chunks: [String]) -> [String] {
        guard chunks.count > 1 else { return chunks }

        var result = chunks
        for index in 1..<result.count {
            guard let overlap = sentences(in: chunks[index - 1]).last else { continue }
            result[index] = overlap + " " + result[index]
        }
        return result
    }
}
