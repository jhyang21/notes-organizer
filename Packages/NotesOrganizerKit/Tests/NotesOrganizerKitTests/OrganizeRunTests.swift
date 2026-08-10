import Foundation
import Testing
@testable import NotesOrganizerKit

/// Throws something that isn't an `OrganizeFailure`, which `MockOrganizer`
/// can't express — the two cases `OrganizeRun` has to handle itself.
private struct ThrowingOrganizer: NoteOrganizing {
    enum Thrown: Sendable {
        case unknown
        case cancelled
    }

    let thrown: Thrown

    func organize(_ text: String) async throws -> OrganizedNote {
        switch thrown {
        case .unknown: throw UnknownError()
        case .cancelled: throw CancellationError()
        }
    }
}

private struct UnknownError: Error {}

@Suite("OrganizeRun")
struct OrganizeRunTests {
    private func makeLog() -> DiagnosticsLog {
        DiagnosticsLog(storage: InMemoryDiagnosticsStorage())
    }

    @Test("a successful run returns the note and records a timing")
    func recordsTimingOnSuccess() async throws {
        let log = makeLog()
        let note = OrganizedNote(title: "Organized", sections: [NoteSection(heading: "H", bullets: ["b"])])
        let run = OrganizeRun(organizer: MockOrganizer(result: note), source: .app, log: log)

        let result = await run.run("one two three four")
        guard case .success(let outcome) = try #require(result) else {
            Issue.record("expected a note, got \(String(describing: result))")
            return
        }

        #expect(outcome.note == note)
        #expect(outcome.wordCount == 4)
        #expect(outcome.duration >= 0)

        let timings = log.organizeTimings()
        #expect(timings.count == 1)
        #expect(timings.first?.source == .app)
        #expect(timings.first?.wordCount == 4)
        #expect(log.events().isEmpty)
    }

    @Test("an organize failure comes back as a failure and is recorded as an event")
    func recordsEventOnFailure() async throws {
        let log = makeLog()
        let run = OrganizeRun(
            organizer: MockOrganizer(error: .emptyTranscript),
            source: .shareExtension,
            log: log
        )

        let result = await run.run("some text")
        guard case .failure(let failure) = try #require(result) else {
            Issue.record("expected a failure, got \(String(describing: result))")
            return
        }

        #expect(failure == .emptyTranscript)
        #expect(log.organizeTimings().isEmpty)
        #expect(log.events().count == 1)
        #expect(log.events().first?.source == .shareExtension)
    }

    @Test("an error that isn't an OrganizeFailure becomes a fixed line, not the error's own")
    func normalizesUnknownErrors() async throws {
        let log = makeLog()
        let run = OrganizeRun(organizer: ThrowingOrganizer(thrown: .unknown), source: .app, log: log)

        let result = await run.run("some text")
        guard case .failure(.cloudUnavailable(let reason)) = try #require(result) else {
            Issue.record("expected cloudUnavailable, got \(String(describing: result))")
            return
        }

        // Whatever the error said goes to the log, not to the user.
        #expect(reason == "Something went wrong.")
        #expect(log.events().count == 1)
        #expect(log.events().first?.message.contains("Organize failed") == true)
        #expect(log.organizeTimings().isEmpty)
    }

    @Test("cancellation returns nothing and records nothing")
    func cancellationIsSilent() async {
        let log = makeLog()
        let run = OrganizeRun(organizer: ThrowingOrganizer(thrown: .cancelled), source: .app, log: log)

        let result = await run.run("some text")

        #expect(result == nil)
        #expect(log.organizeTimings().isEmpty)
        #expect(log.events().isEmpty)
    }
}
