import Foundation

/// Decides what to do with a model result that `OutputSanitizer` flags as
/// over-summarized: accept it, ask the model again with the retry
/// instructions, or reject it and let the caller fail. Pure, so the retry
/// rule is unit-testable without ever touching the model.
enum OverSummarizationPolicy {
    /// How many times the organizer re-asks the model before rejecting.
    static let maxRetries = 1

    enum Decision: Equatable {
        case accept
        case retry
        case reject
    }

    /// - Parameter attempt: 0 for the first model call, 1 after one retry.
    static func decide(input: String, output: OrganizedNote, attempt: Int) -> Decision {
        guard OutputSanitizer.isOverSummarized(input: input, output: output) else { return .accept }
        return attempt < maxRetries ? .retry : .reject
    }
}
