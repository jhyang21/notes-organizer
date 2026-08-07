import Testing
@testable import NotesOrganizerKit

@Suite("OrganizedNote")
struct OrganizedNoteTests {
    @Test("stores title and body as given")
    func storesFields() {
        let note = OrganizedNote(title: "Groceries", body: "- milk\n- eggs")
        #expect(note.title == "Groceries")
        #expect(note.body == "- milk\n- eggs")
    }

    @Test("equality is field-wise")
    func equality() {
        let a = OrganizedNote(title: "A", body: "B")
        let b = OrganizedNote(title: "A", body: "B")
        let c = OrganizedNote(title: "A", body: "C")
        #expect(a == b)
        #expect(a != c)
    }
}
