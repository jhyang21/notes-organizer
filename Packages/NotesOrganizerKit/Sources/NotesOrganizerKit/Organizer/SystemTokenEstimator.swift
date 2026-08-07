#if canImport(FoundationModels)
import FoundationModels

/// Counts tokens with the model's own tokenizer where iOS offers it, and
/// falls back to `HeuristicTokenEstimator` everywhere else.
///
/// Worth the feature check: the heuristic's 3.5-characters-per-token guess
/// under-counts on dense text, and an under-count means the organizer sends
/// a chunk the model then rejects, costing a whole re-chunk pass. A real
/// count keeps the single-call path on the transcripts that genuinely fit.
///
/// `SystemLanguageModel.tokenCount(for:)` is async, which is why this
/// conforms to `AsyncTokenEstimating` rather than the synchronous
/// `TokenEstimating` the chunker uses.
struct SystemTokenEstimator: AsyncTokenEstimating {
    private let fallback = HeuristicTokenEstimator()

    func estimatedTokenCount(_ text: String) async -> Int {
        if #available(iOS 26.4, *) {
            if let count = try? await SystemLanguageModel.default.tokenCount(for: text) {
                return count
            }
        }
        return fallback.tokenCount(text)
    }
}
#endif
