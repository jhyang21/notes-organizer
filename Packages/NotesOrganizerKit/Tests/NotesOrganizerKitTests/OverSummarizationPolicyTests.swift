import Testing
@testable import NotesOrganizerKit

@Suite("OverSummarizationPolicy")
struct OverSummarizationPolicyTests {
    private let input = "one two three four five six seven eight nine ten" // 10 words

    private func note(words: Int) -> OrganizedNote {
        let bullet = (1...words).map(String.init).joined(separator: " ")
        return OrganizedNote(sections: [NoteSection(heading: "", bullets: [bullet])])
    }

    @Test("accepts output that kept enough of the input")
    func acceptsFullOutput() {
        #expect(OverSummarizationPolicy.decide(input: input, output: note(words: 9), attempt: 0) == .accept)
        #expect(OverSummarizationPolicy.decide(input: input, output: note(words: 9), attempt: 1) == .accept)
    }

    @Test("retries the first time output comes back too short")
    func retriesOnFirstFailure() {
        #expect(OverSummarizationPolicy.decide(input: input, output: note(words: 3), attempt: 0) == .retry)
    }

    @Test("falls back once the retry also comes back too short")
    func fallsBackAfterRetry() {
        #expect(OverSummarizationPolicy.decide(input: input, output: note(words: 3), attempt: 1) == .fallback)
        #expect(OverSummarizationPolicy.decide(input: input, output: note(words: 3), attempt: 2) == .fallback)
    }

    @Test("never asks the model more than maxRetries extra times")
    func retryBudgetIsBounded() {
        let decisions = (0...(OverSummarizationPolicy.maxRetries + 1)).map {
            OverSummarizationPolicy.decide(input: input, output: note(words: 1), attempt: $0)
        }

        #expect(decisions.filter { $0 == .retry }.count == OverSummarizationPolicy.maxRetries)
        #expect(decisions.last == .fallback)
    }
}
