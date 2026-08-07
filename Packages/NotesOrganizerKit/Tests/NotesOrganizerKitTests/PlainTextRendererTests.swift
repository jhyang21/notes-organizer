import Testing
@testable import NotesOrganizerKit

@Suite("PlainTextRenderer")
struct PlainTextRendererTests {
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

        let expected = "Groceries\n\nPRODUCE\n• Milk\n• Eggs\n\n• Call mom\n\nACTION ITEMS\n☐ Buy a cart"

        #expect(PlainTextRenderer.render(note) == expected)
    }

    @Test("skips the heading line for an unheaded section, with no action items")
    func unheadedSectionNoActionItems() {
        let note = OrganizedNote(title: "Quick Note", sections: [NoteSection(heading: "", bullets: ["Just one thought"])])

        #expect(PlainTextRenderer.render(note) == "Quick Note\n\n• Just one thought")
    }

    @Test("uppercases the heading of a headed section, with no action items")
    func headedSectionNoActionItems() {
        let note = OrganizedNote(title: "Plan", sections: [NoteSection(heading: "Today", bullets: ["Task A"])])

        #expect(PlainTextRenderer.render(note) == "Plan\n\nTODAY\n• Task A")
    }

    @Test("renders action items with no sections")
    func actionItemsOnlyNoSections() {
        let note = OrganizedNote(title: "Reminders", actionItems: ["Call Bob", "Email Alice"])

        #expect(PlainTextRenderer.render(note) == "Reminders\n\nACTION ITEMS\n☐ Call Bob\n☐ Email Alice")
    }

    @Test("renders a fully empty note as an empty string")
    func emptyNote() {
        #expect(PlainTextRenderer.render(OrganizedNote(title: "")) == "")
    }
}
