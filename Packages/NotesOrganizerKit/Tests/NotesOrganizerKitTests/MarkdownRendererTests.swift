import Testing
@testable import NotesOrganizerKit

@Suite("MarkdownRenderer")
struct MarkdownRendererTests {
    @Test("renders a full note: title, headed section, unheaded section, action items")
    func fullNote() {
        let note = OrganizedNote(
            title: "Groceries",
            sections: [
                NoteSection(heading: "Produce", bullets: ["Milk", "Eggs"]),
                NoteSection(heading: "", bullets: ["Call mom"]),
            ],
            actionItems: ["Buy a cart"]
        )

        let expected = """
        # Groceries

        ## Produce
        - Milk
        - Eggs

        - Call mom

        ## Action Items
        - [ ] Buy a cart
        """

        #expect(MarkdownRenderer.render(note) == expected)
    }

    @Test("skips the heading line for an unheaded section, with no action items")
    func unheadedSectionNoActionItems() {
        let note = OrganizedNote(title: "Quick Note", sections: [NoteSection(heading: "", bullets: ["Just one thought"])])

        #expect(MarkdownRenderer.render(note) == "# Quick Note\n\n- Just one thought")
    }

    @Test("renders a headed section with no action items")
    func headedSectionNoActionItems() {
        let note = OrganizedNote(title: "Plan", sections: [NoteSection(heading: "Today", bullets: ["Task A"])])

        #expect(MarkdownRenderer.render(note) == "# Plan\n\n## Today\n- Task A")
    }

    @Test("renders action items with no sections")
    func actionItemsOnlyNoSections() {
        let note = OrganizedNote(title: "Reminders", actionItems: ["Call Bob", "Email Alice"])

        #expect(MarkdownRenderer.render(note) == "# Reminders\n\n## Action Items\n- [ ] Call Bob\n- [ ] Email Alice")
    }

    @Test("renders a fully empty note as a bare title line")
    func emptyNote() {
        #expect(MarkdownRenderer.render(OrganizedNote(title: "")) == "# ")
    }
}
