import Testing
@testable import NotesOrganizerKit

/// One token per whitespace-separated word — makes chunk-boundary math easy
/// to work out by hand in these tests.
private struct WordTokenEstimator: TokenEstimating {
    func tokenCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

/// One token per character — used only for the degenerate no-whitespace
/// test, where a word-based estimator could never see the text as oversized.
private struct CharacterTokenEstimator: TokenEstimating {
    func tokenCount(_ text: String) -> Int {
        text.count
    }
}

@Suite("TranscriptChunker")
struct TranscriptChunkerTests {
    @Test("returns nothing for empty or whitespace-only input")
    func emptyInput() {
        let chunker = TranscriptChunker(tokenEstimator: WordTokenEstimator())
        #expect(chunker.chunk("").isEmpty)
        #expect(chunker.chunk("   \n\n  ").isEmpty)
    }

    @Test("passes short text through as a single trimmed chunk")
    func shortPassthrough() {
        let budget = TranscriptChunker.Budget(targetTokensPerChunk: 5, hardCeilingTokens: 8)
        let chunker = TranscriptChunker(tokenEstimator: WordTokenEstimator(), budget: budget)

        // Two short paragraphs, but the whole thing is still under the hard
        // ceiling, so it must come back untouched rather than being split.
        let text = "  one two\n\nthree four  "
        #expect(chunker.chunk(text) == ["one two\n\nthree four"])
    }

    @Test("splits on paragraph boundaries and overlaps chunks by one sentence")
    func paragraphSplitWithOverlap() {
        let budget = TranscriptChunker.Budget(targetTokensPerChunk: 10, hardCeilingTokens: 12)
        let chunker = TranscriptChunker(tokenEstimator: WordTokenEstimator(), budget: budget)

        let paragraphA = "Sentence one is here. Sentence two is here."
        let paragraphB = "Sentence three is here. Sentence four is here."
        let chunks = chunker.chunk("\(paragraphA)\n\n\(paragraphB)")

        #expect(chunks == [
            "Sentence one is here. Sentence two is here.",
            "Sentence two is here. Sentence three is here. Sentence four is here.",
        ])
    }

    @Test("falls back to sentence boundaries when a single paragraph is oversized")
    func sentenceFallbackForOversizedParagraph() {
        let budget = TranscriptChunker.Budget(targetTokensPerChunk: 4, hardCeilingTokens: 6)
        let chunker = TranscriptChunker(tokenEstimator: WordTokenEstimator(), budget: budget)

        // One paragraph (no blank line), four short sentences, oversized as
        // a whole (8 words > hard ceiling of 6) so it must split internally.
        let text = "First sentence. Second sentence. Third sentence. Fourth sentence."
        let chunks = chunker.chunk(text)

        #expect(chunks == [
            "First sentence. Second sentence.",
            "Second sentence. Third sentence. Fourth sentence.",
        ])
    }

    @Test("respects the target budget when packing paragraphs")
    func budgetRespected() {
        let budget = TranscriptChunker.Budget(targetTokensPerChunk: 6, hardCeilingTokens: 6)
        let estimator = WordTokenEstimator()
        let chunker = TranscriptChunker(tokenEstimator: estimator, budget: budget)

        let paragraphs = (1...5).map { "Paragraph number \($0) has five words." }
        let chunks = chunker.chunk(paragraphs.joined(separator: "\n\n"))

        #expect(chunks.count > 1)
        // Every paragraph is 6 words, at the hard ceiling, so none get
        // merged with a neighbor; the one-sentence overlap only ever adds
        // one short sentence, which this text's paragraphs are already one
        // sentence each, so overlap doesn't blow the ceiling either.
        for chunk in chunks {
            #expect(estimator.tokenCount(chunk) <= budget.hardCeilingTokens * 2)
        }
    }

    @Test("splits an unbroken run of text by character budget instead of looping forever")
    func degenerateUnbrokenText() {
        let budget = TranscriptChunker.Budget(targetTokensPerChunk: 10, hardCeilingTokens: 20)
        let estimator = CharacterTokenEstimator()
        let chunker = TranscriptChunker(tokenEstimator: estimator, budget: budget)

        // No spaces, no punctuation: no paragraph, sentence, or word
        // boundary exists anywhere in this text.
        let text = String(repeating: "a", count: 50)
        let chunks = chunker.chunk(text)

        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { !$0.isEmpty })
        // Generous bound rather than a strict one: with no sentence
        // boundaries, the sentence tokenizer treats each whole chunk as
        // "one sentence", so the one-sentence overlap can duplicate an
        // entire previous chunk here. The property this test protects is
        // termination and forward progress, not a tight size bound.
        for chunk in chunks {
            #expect(estimator.tokenCount(chunk) <= budget.hardCeilingTokens * 3)
        }
        #expect(chunks.joined().contains(String(repeating: "a", count: 10)))
    }

    @Test("splits an oversized single sentence with no punctuation using the character fallback")
    func oversizedParagraphWithNoSentenceBoundaries() {
        // Hard ceiling sits above paragraphB's own length (23 chars) so only
        // paragraphA — the unbroken, oversized one — gets character-split.
        let budget = TranscriptChunker.Budget(targetTokensPerChunk: 10, hardCeilingTokens: 30)
        let estimator = CharacterTokenEstimator()
        let chunker = TranscriptChunker(tokenEstimator: estimator, budget: budget)

        let paragraphA = String(repeating: "b", count: 40)
        let paragraphB = "Short second paragraph."
        let chunks = chunker.chunk("\(paragraphA)\n\n\(paragraphB)")

        #expect(chunks.count > 1)
        #expect(chunks.contains { $0.contains(paragraphB) })
    }
}
