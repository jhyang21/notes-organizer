import Foundation

/// Estimates how many model tokens a string costs, so `TranscriptChunker`
/// can keep chunks within the model's context window.
protocol TokenEstimating: Sendable {
    func tokenCount(_ text: String) -> Int
}

/// A cheap, model-free estimate: roughly 3.5 characters per token, rounded
/// up. Good enough for chunking decisions; M5 adds a
/// `SystemLanguageModel`-based estimator for cases that need precision.
struct HeuristicTokenEstimator: TokenEstimating {
    private static let charactersPerToken = 3.5

    func tokenCount(_ text: String) -> Int {
        let characterCount = text.count
        guard characterCount > 0 else { return 0 }
        return Int((Double(characterCount) / Self.charactersPerToken).rounded(.up))
    }
}
