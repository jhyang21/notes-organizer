import Testing
@testable import NotesOrganizerKit

@Suite("OutputSanitizer sanitize")
struct OutputSanitizerSanitizeTests {
    @Test("collapses internal whitespace and newlines everywhere")
    func collapsesWhitespace() {
        let note = OrganizedNote(
            title: "  My   Title\n",
            sections: [NoteSection(heading: " Head  ing ", bullets: ["one\ntwo   three"])],
            actionItems: ["  do   it  "]
        )

        let sanitized = OutputSanitizer.sanitize(note)

        #expect(sanitized.title == "My Title")
        #expect(sanitized.sections == [NoteSection(heading: "Head ing", bullets: ["one two three"])])
        #expect(sanitized.actionItems == ["do it"])
    }

    @Test("drops empty bullets")
    func dropsEmptyBullets() {
        let note = OrganizedNote(sections: [NoteSection(heading: "H", bullets: ["Keep", "  ", "", "Also keep"])])

        let sanitized = OutputSanitizer.sanitize(note)

        #expect(sanitized.sections == [NoteSection(heading: "H", bullets: ["Keep", "Also keep"])])
    }

    @Test("drops a section entirely once all its bullets are empty")
    func dropsEmptySection() {
        let note = OrganizedNote(sections: [
            NoteSection(heading: "Empty", bullets: ["", "   "]),
            NoteSection(heading: "Real", bullets: ["Keep"]),
        ])

        let sanitized = OutputSanitizer.sanitize(note)

        #expect(sanitized.sections == [NoteSection(heading: "Real", bullets: ["Keep"])])
    }

    @Test("caps heading length at a word boundary")
    func capsHeadingLength() {
        let longHeading = Array(repeating: "word", count: 20).joined(separator: " ") // well over 60 chars
        let note = OrganizedNote(sections: [NoteSection(heading: longHeading, bullets: ["b"])])

        let sanitized = OutputSanitizer.sanitize(note)

        let heading = sanitized.sections[0].heading
        #expect(heading.count <= OutputSanitizer.maxHeadingLength)
        #expect(!heading.hasSuffix(" "))
        #expect(longHeading.hasPrefix(heading))
    }

    @Test("dedupes only identical adjacent bullets, case-insensitively")
    func dedupesAdjacentBulletsOnly() {
        let note = OrganizedNote(sections: [NoteSection(heading: "H", bullets: ["A", "a", "B", "A"])])

        let sanitized = OutputSanitizer.sanitize(note)

        // The second "A" survives: it isn't adjacent to the first.
        #expect(sanitized.sections == [NoteSection(heading: "H", bullets: ["A", "B", "A"])])
    }

    @Test("dedupes action items case-insensitively across the whole list")
    func dedupesActionItems() {
        let note = OrganizedNote(actionItems: ["Call Bob", "call bob", "Email Alice"])

        let sanitized = OutputSanitizer.sanitize(note)

        #expect(sanitized.actionItems == ["Call Bob", "Email Alice"])
    }
}

@Suite("OutputSanitizer isOverSummarized")
struct OutputSanitizerOverSummarizedTests {
    private let input = "one two three four five six seven eight nine ten" // 10 words

    @Test("flags output below 60% of input word count")
    func flagsBelowThreshold() {
        let output = OrganizedNote(sections: [NoteSection(heading: "", bullets: ["one two three four five"])]) // 5 words
        #expect(OutputSanitizer.isOverSummarized(input: input, output: output))
    }

    @Test("does not flag output at exactly 60% of input word count")
    func doesNotFlagAtBoundary() {
        let output = OrganizedNote(sections: [NoteSection(heading: "", bullets: ["one two three four five six"])]) // 6 words = 60%
        #expect(!OutputSanitizer.isOverSummarized(input: input, output: output))
    }

    @Test("does not flag output above 60% of input word count")
    func doesNotFlagAboveThreshold() {
        let output = OrganizedNote(sections: [NoteSection(heading: "", bullets: ["one two three four five six seven"])]) // 7 words
        #expect(!OutputSanitizer.isOverSummarized(input: input, output: output))
    }

    @Test("never flags an empty input")
    func neverFlagsEmptyInput() {
        #expect(!OutputSanitizer.isOverSummarized(input: "", output: OrganizedNote(title: "")))
        #expect(!OutputSanitizer.isOverSummarized(input: "   ", output: OrganizedNote(title: "")))
    }

    @Test("counts words across title, headings, bullets, and action items")
    func countsAcrossAllFields() {
        let output = OrganizedNote(
            title: "one two",
            sections: [NoteSection(heading: "three", bullets: ["four five"])],
            actionItems: ["six"]
        ) // 6 words total = 60%
        #expect(!OutputSanitizer.isOverSummarized(input: input, output: output))
    }
}
