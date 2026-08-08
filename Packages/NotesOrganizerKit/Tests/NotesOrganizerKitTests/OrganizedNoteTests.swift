import Foundation
import Testing
@testable import NotesOrganizerKit

@Suite("OrganizedNote")
struct OrganizedNoteTests {
    @Test("stores title, sections, and action items as given")
    func storesFields() {
        let note = OrganizedNote(
            title: "Groceries",
            sections: [NoteSection(heading: "Produce", bullets: ["Milk", "Eggs"])],
            actionItems: ["Buy a cart"]
        )
        #expect(note.title == "Groceries")
        #expect(note.sections == [NoteSection(heading: "Produce", bullets: ["Milk", "Eggs"])])
        #expect(note.actionItems == ["Buy a cart"])
    }

    @Test("defaults sections and action items to empty")
    func defaultsToEmpty() {
        let note = OrganizedNote(title: "Untitled")
        #expect(note.sections.isEmpty)
        #expect(note.actionItems.isEmpty)
    }

    @Test("equality is field-wise")
    func equality() {
        let a = OrganizedNote(title: "A", sections: [NoteSection(heading: "H", bullets: ["B"])])
        let b = OrganizedNote(title: "A", sections: [NoteSection(heading: "H", bullets: ["B"])])
        let c = OrganizedNote(title: "A", sections: [NoteSection(heading: "H", bullets: ["C"])])
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - The wire format

    @Test("survives a JSON round trip")
    func codableRoundTrip() throws {
        let note = OrganizedNote(
            title: "Kitchen quotes",
            sections: [NoteSection(heading: "Quotes", bullets: ["Bosch quoted 4200", "Miele quoted 5100"])],
            actionItems: ["Call Priya"]
        )

        let decoded = try JSONDecoder().decode(OrganizedNote.self, from: try JSONEncoder().encode(note))
        #expect(decoded == note)
    }

    @Test("a response with no action items is a note, not a failure")
    func decodesMissingKeys() throws {
        let json = Data(#"{"title":"T","sections":[{"heading":"H"}]}"#.utf8)

        let decoded = try JSONDecoder().decode(OrganizedNote.self, from: json)
        #expect(decoded == OrganizedNote(title: "T", sections: [NoteSection(heading: "H")]))
    }
}

@Suite("NoteSection")
struct NoteSectionTests {
    @Test("equality is field-wise")
    func equality() {
        let a = NoteSection(heading: "H", bullets: ["1", "2"])
        let b = NoteSection(heading: "H", bullets: ["1", "2"])
        let c = NoteSection(heading: "H", bullets: ["1"])
        #expect(a == b)
        #expect(a != c)
    }
}
