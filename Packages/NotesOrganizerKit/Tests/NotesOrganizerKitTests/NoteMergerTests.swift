import Testing
@testable import NotesOrganizerKit

@Suite("NoteMerger")
struct NoteMergerTests {
    @Test("concatenates sections from each note in order")
    func preservesOrder() {
        let notes = [
            OrganizedNote(title: "A", sections: [NoteSection(heading: "First", bullets: ["1"])]),
            OrganizedNote(title: "B", sections: [NoteSection(heading: "Second", bullets: ["2"])]),
        ]

        let merged = NoteMerger.merge(notes)

        #expect(merged.sections == [
            NoteSection(heading: "First", bullets: ["1"]),
            NoteSection(heading: "Second", bullets: ["2"]),
        ])
    }

    @Test("merges adjacent sections whose headings match case-insensitively and trimmed")
    func mergesAdjacentMatchingHeadings() {
        let notes = [
            OrganizedNote(title: "A", sections: [NoteSection(heading: "To Do", bullets: ["1"])]),
            OrganizedNote(title: "B", sections: [NoteSection(heading: "  to do  ", bullets: ["2"])]),
        ]

        let merged = NoteMerger.merge(notes)

        #expect(merged.sections == [NoteSection(heading: "To Do", bullets: ["1", "2"])])
    }

    @Test("does not merge same-heading sections that aren't adjacent")
    func doesNotMergeNonAdjacentHeadings() {
        let notes = [
            OrganizedNote(title: "A", sections: [
                NoteSection(heading: "H", bullets: ["1"]),
                NoteSection(heading: "Other", bullets: ["x"]),
            ]),
            OrganizedNote(title: "B", sections: [NoteSection(heading: "H", bullets: ["2"])]),
        ]

        let merged = NoteMerger.merge(notes)

        #expect(merged.sections == [
            NoteSection(heading: "H", bullets: ["1"]),
            NoteSection(heading: "Other", bullets: ["x"]),
            NoteSection(heading: "H", bullets: ["2"]),
        ])
    }

    @Test("merges adjacent sections that both have an empty heading")
    func mergesAdjacentEmptyHeadings() {
        let notes = [
            OrganizedNote(title: "A", sections: [NoteSection(heading: "", bullets: ["1"])]),
            OrganizedNote(title: "B", sections: [NoteSection(heading: "", bullets: ["2"])]),
        ]

        let merged = NoteMerger.merge(notes)

        #expect(merged.sections == [NoteSection(heading: "", bullets: ["1", "2"])])
    }

    @Test("dedupes action items across notes case-insensitively, keeping first wording")
    func dedupesActionItems() {
        let notes = [
            OrganizedNote(title: "A", actionItems: ["Call Bob", "Email Alice"]),
            OrganizedNote(title: "B", actionItems: ["call bob", "Buy milk"]),
        ]

        let merged = NoteMerger.merge(notes)

        #expect(merged.actionItems == ["Call Bob", "Email Alice", "Buy milk"])
    }

    @Test("title falls back to the first chunk with a non-empty title")
    func titleFallsBackToFirstNonEmpty() {
        let notes = [
            OrganizedNote(title: ""),
            OrganizedNote(title: "Real Title"),
            OrganizedNote(title: "Ignored"),
        ]

        #expect(NoteMerger.merge(notes).title == "Real Title")
    }

    @Test("merging an empty array yields an empty note")
    func mergingEmptyArray() {
        #expect(NoteMerger.merge([]) == OrganizedNote(title: ""))
    }
}
