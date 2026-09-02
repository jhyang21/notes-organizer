import Foundation
import Testing
@testable import NotesOrganizerKit

/// Throws something that isn't an `OrganizeFailure`, which `MockOrganizer`
/// can't express — the two cases `OrganizeRun` has to handle itself. Covers
/// both paths, since both go through the same bookkeeping.
private struct ThrowingOrganizer: NoteOrganizing, VoiceOrganizing {
    enum Thrown: Sendable {
        case unknown
        case cancelled
    }

    let thrown: Thrown

    func organize(_ text: String) async throws -> OrganizedNote {
        try throwIt()
    }

    func organize(audioAt url: URL, durationSeconds: Double, locale: Locale) async throws -> OrganizedNote {
        try throwIt()
    }

    private func throwIt() throws -> OrganizedNote {
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

    private let recording = URL(fileURLWithPath: "/tmp/capture-test.m4a")

    @Test("a successful run returns the note and records a timing")
    func recordsTimingOnSuccess() async throws {
        let log = makeLog()
        let note = OrganizedNote(title: "Organized", sections: [NoteSection(heading: "H", items: ["b"])])
        let run = OrganizeRun(source: .app, log: log)

        let result = await run.run("one two three four", with: MockOrganizer(result: note))
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

    @Test("a voice run reaches the voice organizer and is logged like any other")
    func recordsTimingOnVoiceSuccess() async throws {
        let log = makeLog()
        let note = OrganizedNote(
            title: "Kitchen quotes",
            sections: [NoteSection(heading: "Quotes", kind: .bullets, items: ["Bosch quoted 4200"])]
        )
        let organizer = MockOrganizer(result: note)

        let result = await OrganizeRun(source: .app, log: log)
            .run(audioAt: recording, durationSeconds: 42, locale: Locale(identifier: "en_US"), with: organizer)
        guard case .success(let outcome) = try #require(result) else {
            Issue.record("expected a note, got \(String(describing: result))")
            return
        }

        #expect(outcome.note == note)
        #expect(await organizer.receivedRecordings == [recording])
        // The transcript never reaches the device, so the words are counted on
        // the note that came back — "Kitchen quotes", "Quotes", and the item.
        // On the note's own text, so the renderer's bullet isn't a word — a
        // render of this note would count seven.
        #expect(outcome.wordCount == 6)

        let timings = log.organizeTimings()
        #expect(timings.count == 1)
        #expect(timings.first?.wordCount == outcome.wordCount)
        #expect(log.events().isEmpty)
    }

    @Test("an organize failure comes back as a failure and is recorded as an event")
    func recordsEventOnFailure() async throws {
        let log = makeLog()
        let run = OrganizeRun(source: .shareExtension, log: log)

        let result = await run.run("some text", with: MockOrganizer(error: .emptyTranscript))
        guard case .failure(let failure) = try #require(result) else {
            Issue.record("expected a failure, got \(String(describing: result))")
            return
        }

        #expect(failure == .emptyTranscript)
        #expect(log.organizeTimings().isEmpty)
        #expect(log.events().count == 1)
        #expect(log.events().first?.source == .shareExtension)
    }

    @Test("a voice failure is recorded the same way a text one is")
    func recordsEventOnVoiceFailure() async throws {
        let log = makeLog()

        let result = await OrganizeRun(source: .app, log: log)
            .run(
                audioAt: recording,
                durationSeconds: 42,
                locale: Locale(identifier: "en_US"),
                with: MockOrganizer(error: .networkUnavailable)
            )
        guard case .failure(let failure) = try #require(result) else {
            Issue.record("expected a failure, got \(String(describing: result))")
            return
        }

        #expect(failure == .networkUnavailable)
        #expect(log.organizeTimings().isEmpty)
        #expect(log.events().count == 1)
    }

    @Test("an error that isn't an OrganizeFailure becomes a fixed line, not the error's own")
    func normalizesUnknownErrors() async throws {
        let log = makeLog()
        let run = OrganizeRun(source: .app, log: log)

        let result = await run.run("some text", with: ThrowingOrganizer(thrown: .unknown))
        guard case .failure(.cloudUnavailable(let reason)) = try #require(result) else {
            Issue.record("expected cloudUnavailable, got \(String(describing: result))")
            return
        }

        // Whatever the error said goes to the log, not to the user.
        #expect(reason == "Something went wrong. Try again in a moment.")
        #expect(log.events().count == 1)
        #expect(log.events().first?.message.contains("Organize failed") == true)
        #expect(log.organizeTimings().isEmpty)
    }

    @Test("cancellation returns nothing and records nothing, on either path")
    func cancellationIsSilent() async {
        let log = makeLog()
        let run = OrganizeRun(source: .app, log: log)

        #expect(await run.run("some text", with: ThrowingOrganizer(thrown: .cancelled)) == nil)
        let voice = await run.run(
            audioAt: recording,
            durationSeconds: 42,
            locale: Locale(identifier: "en_US"),
            with: ThrowingOrganizer(thrown: .cancelled)
        )
        #expect(voice == nil)

        #expect(log.organizeTimings().isEmpty)
        #expect(log.events().isEmpty)
    }
}
