import Testing
@testable import NotesOrganizerKit

@Suite("NoteFilename")
struct NoteFilenameTests {
    @Test("leaves an ordinary title alone")
    func leavesOrdinaryTitleAlone() {
        #expect(NoteFilename.sanitize("Kitchen Renovation Notes") == "Kitchen Renovation Notes")
    }

    @Test("replaces path-hostile characters with spaces, not escapes")
    func replacesForbiddenCharacters() {
        #expect(NoteFilename.sanitize("Q3/Q4: plan?") == "Q3 Q4 plan")
        #expect(NoteFilename.sanitize("a\\b*c\"d<e>f|g") == "a b c d e f g")
    }

    @Test("collapses the whitespace left behind by replacement")
    func collapsesWhitespace() {
        #expect(NoteFilename.sanitize("Notes  from\tthe\nmeeting") == "Notes from the meeting")
    }

    @Test("falls back to a usable name when nothing survives")
    func fallsBackWhenEmpty() {
        #expect(NoteFilename.sanitize("") == NoteFilename.fallbackName)
        #expect(NoteFilename.sanitize("   ") == NoteFilename.fallbackName)
        #expect(NoteFilename.sanitize("///") == NoteFilename.fallbackName)
        #expect(NoteFilename.sanitize("...") == NoteFilename.fallbackName)
    }

    @Test("never produces a hidden file or a trailing-dot name")
    func trimsLeadingAndTrailingDots() {
        #expect(NoteFilename.sanitize(".hidden note") == "hidden note")
        #expect(NoteFilename.sanitize("Meeting notes.") == "Meeting notes")
    }

    @Test("caps a long title at a word boundary")
    func capsLongTitle() {
        let long = Array(repeating: "word", count: 40).joined(separator: " ")
        let name = NoteFilename.sanitize(long)

        #expect(name.count <= NoteFilename.maxLength)
        #expect(!name.hasSuffix(" "))
        #expect(long.hasPrefix(name))
    }

    @Test("keeps non-ASCII titles readable rather than escaping them")
    func keepsNonASCII() {
        #expect(NoteFilename.sanitize("Café notes — Séoul") == "Café notes — Séoul")
    }
}
