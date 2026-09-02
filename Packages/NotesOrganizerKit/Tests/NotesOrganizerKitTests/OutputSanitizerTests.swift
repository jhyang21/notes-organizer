import Testing
@testable import NotesOrganizerKit

@Suite("OutputSanitizer sanitize")
struct OutputSanitizerSanitizeTests {
    @Test("collapses internal whitespace and newlines everywhere")
    func collapsesWhitespace() {
        let note = OrganizedNote(
            title: "  My   Title\n",
            summary: " Two   quotes,\none timeline. ",
            sections: [NoteSection(heading: " Head  ing ", items: ["one\ntwo   three"])]
        )

        let sanitized = OutputSanitizer.sanitize(note)

        #expect(sanitized.title == "My Title")
        #expect(sanitized.summary == "Two quotes, one timeline.")
        #expect(sanitized.sections == [NoteSection(heading: "Head ing", items: ["one two three"])])
    }

    @Test("drops empty items")
    func dropsEmptyItems() {
        let note = OrganizedNote(sections: [NoteSection(heading: "H", items: ["Keep", "  ", "", "Also keep"])])

        let sanitized = OutputSanitizer.sanitize(note)

        #expect(sanitized.sections == [NoteSection(heading: "H", items: ["Keep", "Also keep"])])
    }

    @Test("drops a section entirely once all its items are empty")
    func dropsEmptySection() {
        let note = OrganizedNote(sections: [
            NoteSection(heading: "Empty", items: ["", "   "]),
            NoteSection(heading: "Real", items: ["Keep"]),
        ])

        let sanitized = OutputSanitizer.sanitize(note)

        #expect(sanitized.sections == [NoteSection(heading: "Real", items: ["Keep"])])
    }

    @Test("caps heading length at a word boundary")
    func capsHeadingLength() {
        let longHeading = Array(repeating: "word", count: 20).joined(separator: " ") // well over 60 chars
        let note = OrganizedNote(sections: [NoteSection(heading: longHeading, items: ["b"])])

        let sanitized = OutputSanitizer.sanitize(note)

        let heading = sanitized.sections[0].heading
        #expect(heading.count <= OutputSanitizer.maxHeadingLength)
        #expect(!heading.hasSuffix(" "))
        #expect(longHeading.hasPrefix(heading))
    }

    @Test("keeps the section kind")
    func keepsTheKind() {
        let note = OrganizedNote(sections: SectionKind.allCases.map {
            NoteSection(heading: "H", kind: $0, items: ["item"])
        })

        #expect(OutputSanitizer.sanitize(note).sections.map(\.kind) == SectionKind.allCases)
    }

    // MARK: - What it deliberately leaves alone

    @Test("repeats are left alone — the server decides what a note says")
    func keepsRepeats() {
        let note = OrganizedNote(sections: [NoteSection(heading: "H", items: ["A", "a", "A"])])

        let sanitized = OutputSanitizer.sanitize(note)

        #expect(sanitized.sections == [NoteSection(heading: "H", items: ["A", "a", "A"])])
    }

    @Test("verbatim items keep their own spacing")
    func leavesVerbatimAlone() {
        let note = OrganizedNote(sections: [
            NoteSection(heading: "Wi-Fi", kind: .verbatim, items: ["Pass:  x7 Q!9", "  indented  "]),
        ])

        let sanitized = OutputSanitizer.sanitize(note)

        #expect(sanitized.sections[0].items.map(\.text) == ["Pass:  x7 Q!9", "  indented  "])
    }

    // MARK: - done

    @Test("a checklist keeps what is done")
    func keepsDoneInAChecklist() {
        let note = OrganizedNote(sections: [
            NoteSection(heading: "To Do", kind: .checklist, items: [
                NoteItem(text: "Call Bob"),
                NoteItem(text: "Email Alice", done: true),
            ]),
        ])

        let sanitized = OutputSanitizer.sanitize(note)

        #expect(sanitized.sections[0].items.map(\.done) == [false, true])
    }

    @Test("done is reset outside a checklist, where there are no boxes to tick")
    func resetsDoneOutsideAChecklist() {
        let kinds = SectionKind.allCases.filter { $0 != .checklist }
        let note = OrganizedNote(sections: kinds.map {
            NoteSection(heading: "H", kind: $0, items: [NoteItem(text: "item", done: true)])
        })

        let sanitized = OutputSanitizer.sanitize(note)

        #expect(sanitized.sections.allSatisfy { $0.items.allSatisfy { !$0.done } })
    }
}
