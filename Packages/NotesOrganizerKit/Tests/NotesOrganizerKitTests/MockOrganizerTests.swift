import Testing
@testable import NotesOrganizerKit

@Suite("MockOrganizer")
struct MockOrganizerTests {
    @Test("returns the configured note and records the transcript it received")
    func returnsConfiguredResult() async throws {
        let note = OrganizedNote(title: "Configured")
        let organizer = MockOrganizer(result: note)

        let result = try await organizer.organize("hello world")

        #expect(result == note)
        #expect(await organizer.receivedTranscripts == ["hello world"])
    }

    @Test("throws the configured error")
    func throwsConfiguredError() async {
        let organizer = MockOrganizer(error: .emptyTranscript)

        await #expect(throws: OrganizeFailure.emptyTranscript) {
            try await organizer.organize("")
        }
    }

    @Test("accumulates every transcript across multiple calls")
    func accumulatesTranscripts() async throws {
        let organizer = MockOrganizer(result: OrganizedNote(title: "T"))

        _ = try await organizer.organize("first")
        _ = try await organizer.organize("second")

        #expect(await organizer.receivedTranscripts == ["first", "second"])
    }

    @Test("setOutcome changes what subsequent calls return")
    func setOutcomeChangesBehavior() async throws {
        let organizer = MockOrganizer(result: OrganizedNote(title: "Before"))

        let first = try await organizer.organize("call one")
        #expect(first.title == "Before")

        await organizer.setOutcome(.failure(.contextOverflow(estimatedTokenCount: 2000)))

        await #expect(throws: OrganizeFailure.contextOverflow(estimatedTokenCount: 2000)) {
            try await organizer.organize("call two")
        }
    }
}
