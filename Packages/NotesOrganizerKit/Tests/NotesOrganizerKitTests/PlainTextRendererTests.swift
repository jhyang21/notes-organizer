import Testing
@testable import NotesOrganizerKit

@Suite("PlainTextRenderer")
struct PlainTextRendererTests {
    /// One note carrying every kind, so the markers are pinned against each
    /// other rather than one at a time.
    private func kitchenNote(summary: String = "") -> OrganizedNote {
        OrganizedNote(
            title: "Kitchen Renovation",
            summary: summary,
            sections: [
                NoteSection(heading: "Quotes", kind: .bullets, items: ["Bosch quoted 4,200 for cabinets"]),
                NoteSection(heading: "To Do", kind: .checklist, items: [
                    NoteItem(text: "Call the contractor back on Thursday"),
                    NoteItem(text: "Send Priya the floor plan", done: true),
                ]),
                NoteSection(heading: "Install Steps", kind: .numbered, items: [
                    "Remove the old units",
                    "Level the floor",
                ]),
                NoteSection(heading: "Contractor Wi-Fi", kind: .verbatim, items: [
                    "SSID: Site-Office",
                    "Pass:  x7 Q!9",
                ]),
            ]
        )
    }

    @Test("renders every section kind, with no trailing newline")
    func fullNote() {
        let expected = """
        Kitchen Renovation

        QUOTES
        • Bosch quoted 4,200 for cabinets

        TO DO
        ☐ Call the contractor back on Thursday
        ☑ Send Priya the floor plan

        INSTALL STEPS
        1. Remove the old units
        2. Level the floor

        CONTRACTOR WI-FI
        SSID: Site-Office
        Pass:  x7 Q!9
        """

        // The golden string ends without a newline, which pins the renderer's
        // "lines joined, not lines terminated" rule as well.
        #expect(PlainTextRenderer.render(kitchenNote()) == expected)
    }

    @Test("a summary sits under the title, one blank line down")
    func summaryFollowsTheTitle() {
        let rendered = PlainTextRenderer.render(
            kitchenNote(summary: "We compared two cabinet quotes and settled the timeline.")
        )

        #expect(rendered.hasPrefix("""
        Kitchen Renovation

        We compared two cabinet quotes and settled the timeline.

        QUOTES
        """))
    }

    @Test("skips the heading line for an unheaded section")
    func unheadedSection() {
        let note = OrganizedNote(title: "Quick Note", sections: [NoteSection(heading: "", items: ["Just one thought"])])

        #expect(PlainTextRenderer.render(note) == "Quick Note\n\n• Just one thought")
    }

    @Test("paragraphs carry no marker and are separated by one blank line")
    func paragraphSpacing() {
        let note = OrganizedNote(title: "Recap", sections: [
            NoteSection(heading: "Background", kind: .paragraph, items: [
                "The old units came out on Tuesday.",
                "The floor turned out to be uneven.",
            ]),
        ])

        #expect(PlainTextRenderer.render(note) == """
        Recap

        BACKGROUND
        The old units came out on Tuesday.

        The floor turned out to be uneven.
        """)
    }

    @Test("a paragraph's own line breaks come through as line breaks")
    func paragraphKeepsItsLineBreaks() {
        let note = OrganizedNote(title: "Reply", sections: [
            NoteSection(heading: "", kind: .paragraph, items: ["Thanks for the update.", "Best,\nDana"]),
        ])

        #expect(PlainTextRenderer.render(note) == """
        Reply

        Thanks for the update.

        Best,
        Dana
        """)
    }

    @Test("numbering restarts in every section")
    func numberingRestartsPerSection() {
        let note = OrganizedNote(title: "Two Jobs", sections: [
            NoteSection(heading: "Cabinets", kind: .numbered, items: ["Measure", "Order"]),
            NoteSection(heading: "Floor", kind: .numbered, items: ["Level", "Seal"]),
        ])

        #expect(PlainTextRenderer.render(note) == """
        Two Jobs

        CABINETS
        1. Measure
        2. Order

        FLOOR
        1. Level
        2. Seal
        """)
    }

    @Test("verbatim keeps its own spacing, untouched")
    func verbatimKeepsSpacing() {
        let note = OrganizedNote(title: "Wi-Fi", sections: [
            NoteSection(heading: "", kind: .verbatim, items: ["Pass:  x7 Q!9", "  indented"]),
        ])

        #expect(PlainTextRenderer.render(note) == "Wi-Fi\n\nPass:  x7 Q!9\n  indented")
    }

    @Test("a blank line inside a verbatim block is drawn as a blank line")
    func verbatimKeepsAnInteriorBlankLine() {
        let note = OrganizedNote(title: "Snippet", sections: [
            NoteSection(heading: "", kind: .verbatim, items: ["func go() {", "", "    return 1", "}"]),
        ])

        #expect(PlainTextRenderer.render(note) == "Snippet\n\nfunc go() {\n\n    return 1\n}")
    }

    @Test("renders a fully empty note as an empty string")
    func emptyNote() {
        #expect(PlainTextRenderer.render(OrganizedNote(title: "")) == "")
    }
}
