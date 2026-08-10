import Foundation

/// Turns raw transcript text into an `OrganizedNote`. `CloudOrganizer` is the
/// only real implementation; tests and SwiftUI previews use `MockOrganizer`
/// instead, so nothing in CI opens a socket.
public protocol NoteOrganizing: Sendable {
    func organize(_ text: String) async throws -> OrganizedNote
}

/// Reasons `organize(_:)` can fail to produce a note. Every one of them is
/// either something the user can act on now — say more, get back online,
/// record it in two parts — or a wall with a way past it. Tidying happens on
/// our servers, so there is no "this iPhone can't" case left to express.
public enum OrganizeFailure: Error, Equatable, Sendable {
    /// There was nothing to organize.
    case emptyTranscript

    /// This month's tidies are spent. A hard wall, not a delay: the only ways
    /// past it are next month or a subscription.
    case cloudQuotaExhausted

    /// The user hasn't been told what TidyNote sends yet. The app asks on
    /// first launch; the share extension can only point at the app, which is
    /// where the question gets answered.
    case cloudConsentNeeded

    /// Tidying needs a connection and there isn't one.
    case networkUnavailable

    /// The recording is longer than the service will take.
    case audioTooLarge

    /// The service answered with something other than a note. `reason` is
    /// user-facing copy, so it names no vendor and no status code.
    case cloudUnavailable(reason: String)
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
