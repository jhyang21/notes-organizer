import Testing
@testable import NotesOrganizerKit

/// The only part of `FoundationModelOrganizer` that is safe to exercise in
/// CI: the near-empty guard, which returns before the organizer ever looks
/// for a model. Everything past that guard needs Apple Intelligence, which
/// simulators don't have — those paths are covered by testing the pure
/// pieces the organizer composes.
@Suite("FoundationModelOrganizer near-empty guard")
struct FoundationModelOrganizerGuardTests {
    @Test("rejects a transcript with too few letters and digits to organize")
    func rejectsNearEmptyTranscript() async {
        let organizer = FoundationModelOrganizer()

        await #expect(throws: OrganizeFailure.emptyTranscript) {
            try await organizer.organize("hi")
        }
    }

    @Test("counts only letters and digits, not punctuation or whitespace")
    func ignoresPunctuationWhenMeasuring() async {
        let organizer = FoundationModelOrganizer()

        await #expect(throws: OrganizeFailure.emptyTranscript) {
            try await organizer.organize("...  ---  !!!  a b c")
        }
    }

    @Test("rejects an empty transcript")
    func rejectsEmptyTranscript() async {
        let organizer = FoundationModelOrganizer()

        await #expect(throws: OrganizeFailure.emptyTranscript) {
            try await organizer.organize("   \n\n  ")
        }
    }
}
