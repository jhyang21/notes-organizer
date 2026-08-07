import Foundation

/// Estimates how many model tokens a string costs, so `TranscriptChunker`
/// can keep chunks within the model's context window.
protocol TokenEstimating: Sendable {
    func tokenCount(_ text: String) -> Int
}

/// The same job, for estimators that have to await an answer. The model's
/// own tokenizer (`SystemTokenEstimator`) is async, and `TranscriptChunker`
/// calls its estimator inside a tight synchronous loop — so the two stay
/// separate protocols rather than making the chunker async. The organizer
/// awaits this once, to choose between the single-call and chunked paths;
/// the chunker keeps the synchronous heuristic for its inner loop.
protocol AsyncTokenEstimating: Sendable {
    func estimatedTokenCount(_ text: String) async -> Int
}

/// A cheap, model-free estimate: roughly 3.5 characters per token, rounded
/// up. Good enough for chunking decisions, and the fallback whenever the
/// model's own tokenizer isn't available.
struct HeuristicTokenEstimator: TokenEstimating, AsyncTokenEstimating {
    private static let charactersPerToken = 3.5

    func tokenCount(_ text: String) -> Int {
        let characterCount = text.count
        guard characterCount > 0 else { return 0 }
        return Int((Double(characterCount) / Self.charactersPerToken).rounded(.up))
    }

    func estimatedTokenCount(_ text: String) async -> Int {
        tokenCount(text)
    }
}
