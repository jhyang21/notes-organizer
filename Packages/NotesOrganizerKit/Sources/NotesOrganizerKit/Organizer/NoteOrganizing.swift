import Foundation

/// Turns raw transcript text into an `OrganizedNote`. The real
/// implementation (M5) wraps Apple's on-device language model; tests and
/// SwiftUI previews use `MockOrganizer` instead, since CI simulators have
/// no Apple Intelligence model to call.
public protocol NoteOrganizing: Sendable {
    func organize(_ text: String) async throws -> OrganizedNote
}

/// Reasons `organize(_:)` can fail to produce a note.
public enum OrganizeFailure: Error, Equatable, Sendable {
    /// The device doesn't support Apple Intelligence at all.
    case deviceNotEligible

    /// The device supports Apple Intelligence, but the user hasn't turned
    /// it on in Settings.
    case appleIntelligenceNotEnabled

    /// Apple Intelligence is enabled but the on-device model assets aren't
    /// ready yet (still downloading, or temporarily unavailable).
    case modelNotReady(reason: String)

    /// There was nothing to organize.
    case emptyTranscript

    /// A single chunk still exceeds the hard per-call token ceiling after
    /// chunking, so it can't be sent to the model.
    case contextOverflow(estimatedTokenCount: Int)

    /// The model's output kept losing content even after a retry — see
    /// `OutputSanitizer.isOverSummarized`. In normal operation this is
    /// masked by the deterministic formatting fallback, so callers should
    /// rarely see it thrown.
    case overSummarized(inputWordCount: Int, outputWordCount: Int)
}

/// A configurable `NoteOrganizing` stand-in for tests and SwiftUI previews.
/// An actor, so it's trivially `Sendable` and safe to call from concurrent
/// test code without extra locking.
public actor MockOrganizer: NoteOrganizing {
    public enum Outcome: Sendable {
        case success(OrganizedNote)
        case failure(OrganizeFailure)
    }

    private var outcome: Outcome
    public private(set) var receivedTranscripts: [String] = []

    public init(result: OrganizedNote) {
        self.outcome = .success(result)
    }

    public init(error: OrganizeFailure) {
        self.outcome = .failure(error)
    }

    public init(outcome: Outcome) {
        self.outcome = outcome
    }

    /// Changes what the next `organize(_:)` call returns — lets a single
    /// mock simulate a sequence of outcomes (e.g. a retry that succeeds).
    public func setOutcome(_ outcome: Outcome) {
        self.outcome = outcome
    }

    public func organize(_ text: String) async throws -> OrganizedNote {
        receivedTranscripts.append(text)
        switch outcome {
        case .success(let note):
            return note
        case .failure(let error):
            throw error
        }
    }
}
