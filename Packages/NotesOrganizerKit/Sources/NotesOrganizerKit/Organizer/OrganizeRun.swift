import Foundation

/// One organize, with the bookkeeping that every caller was doing by hand:
/// count the words, time the call, record the timing when it works and an
/// event when it doesn't, and turn anything the organizer throws into an
/// `OrganizeFailure` the UI already knows how to show.
///
/// The app and the share extension both go through this, so a run is logged
/// the same way whichever one started it — and whether it started from typed
/// text or from a recording.
///
/// The organizer is handed to the call rather than held here, because there
/// are two kinds of call and only one of them takes text. That way a run
/// can't be built around one organizer and asked for the other.
public struct OrganizeRun: Sendable {
    /// A finished run: the note, and the two numbers that were measured to
    /// log it. Handed back so a caller that wants to show them doesn't have to
    /// time the same call twice.
    public struct Outcome: Equatable, Sendable {
        public let note: OrganizedNote
        public let wordCount: Int
        public let duration: TimeInterval
    }

    private let source: DiagnosticsSource
    private let log: DiagnosticsLog
    private let clock = ContinuousClock()

    public init(source: DiagnosticsSource, log: DiagnosticsLog = .shared) {
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
    public func run(_ text: String, with organizer: NoteOrganizing) async -> Result<Outcome, OrganizeFailure>? {
        let wordCount = WordCounter.count(text)
        return await measure(wordCount: { _ in wordCount }) {
            try await organizer.organize(text)
        }
    }

    /// The same run from a recording: the service transcribes it and organizes
    /// the transcript in one call, so this is the app's only voice path.
    ///
    /// The words are counted on the note that comes back, not on what was
    /// said — the transcript never reaches this device. It is the closest
    /// number there is to the text path's, and it is what the diagnostics
    /// table shows a voice run against.
    public func run(
        audioAt url: URL,
        durationSeconds: Double,
        locale: Locale,
        with organizer: VoiceOrganizing
    ) async -> Result<Outcome, OrganizeFailure>? {
        await measure(wordCount: { WordCounter.count(PlainTextRenderer.render($0)) }) {
            try await organizer.organize(audioAt: url, durationSeconds: durationSeconds, locale: locale)
        }
    }

    /// Everything the two paths agree on. Only the call and how its words are
    /// counted differ, and the count is taken from the note so a path with no
    /// input text of its own still has something true to log.
    private func measure(
        wordCount: (OrganizedNote) -> Int,
        organize: () async throws -> OrganizedNote
    ) async -> Result<Outcome, OrganizeFailure>? {
        let started = clock.now

        do {
            let note = try await organize()
            let duration = (clock.now - started).totalSeconds
            let words = wordCount(note)
            log.recordOrganizeTiming(source: source, wordCount: words, duration: duration)
            return .success(Outcome(note: note, wordCount: words, duration: duration))
        } catch is CancellationError {
            return nil
        } catch let failure as OrganizeFailure {
            log.recordEvent(source: source, message: "Organize failed: \(failure)")
            return .failure(failure)
        } catch {
            // Nothing else the organizer throws is a failure this app has a
            // screen for. The user gets a fixed line and a retry, which is the
            // only useful thing to offer for an error we can't name; the
            // error's own words go to the log, where they help, rather than
            // onto a screen, where they would only alarm.
            log.recordEvent(source: source, message: "Organize failed: \(error.localizedDescription)")
            return .failure(.cloudUnavailable(reason: String(localized: "Something went wrong. Try again in a moment.", bundle: .module)))
        }
    }
}
