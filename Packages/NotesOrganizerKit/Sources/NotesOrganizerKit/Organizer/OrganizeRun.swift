import Foundation

/// One organize, with the bookkeeping that every caller was doing by hand:
/// count the words, time the call, record the timing when it works and an
/// event when it doesn't, and turn anything the organizer throws into an
/// `OrganizeFailure` the UI already knows how to show.
///
/// The app, the share extension, and the diagnostics screen all go through
/// this, so a run is logged the same way whichever one started it.
public struct OrganizeRun: Sendable {
    /// A finished run: the note, and the two numbers that were measured to
    /// log it. Handed back so a caller that wants to show them — the
    /// diagnostics screen — doesn't have to time the same call twice.
    public struct Outcome: Equatable, Sendable {
        public let note: OrganizedNote
        public let wordCount: Int
        public let duration: TimeInterval
    }

    private let organizer: NoteOrganizing
    private let source: DiagnosticsSource
    private let log: DiagnosticsLog
    private let clock = ContinuousClock()

    public init(organizer: NoteOrganizing, source: DiagnosticsSource, log: DiagnosticsLog = .shared) {
        self.organizer = organizer
        self.source = source
        self.log = log
    }

    /// Organizes `text`, or `nil` if the run was cancelled.
    ///
    /// Cancellation isn't a failure and has no screen: it means the caller
    /// walked away — the user hit "New note" mid-organize — and has already
    /// moved its own state on. Painting a failure over that would be wrong,
    /// so `nil` says "nothing to show, and nothing to say about it", and it
    /// is deliberately not logged.
    public func run(_ text: String) async -> Result<Outcome, OrganizeFailure>? {
        let wordCount = WordCounter.count(text)
        let started = clock.now

        do {
            let note = try await organizer.organize(text)
            let duration = (clock.now - started).totalSeconds
            log.recordOrganizeTiming(source: source, wordCount: wordCount, duration: duration)
            return .success(Outcome(note: note, wordCount: wordCount, duration: duration))
        } catch is CancellationError {
            return nil
        } catch let failure as OrganizeFailure {
            log.recordEvent(source: source, message: "Organize failed: \(failure)")
            return .failure(failure)
        } catch {
            // Nothing else the organizer throws is a failure this app has a
            // screen for. `.modelNotReady` is the honest reading — it says
            // what went wrong and offers a retry, which is the only useful
            // thing to offer for an error we can't name.
            let failure = OrganizeFailure.modelNotReady(reason: error.localizedDescription)
            log.recordEvent(source: source, message: "Organize failed: \(error.localizedDescription)")
            return .failure(failure)
        }
    }
}
