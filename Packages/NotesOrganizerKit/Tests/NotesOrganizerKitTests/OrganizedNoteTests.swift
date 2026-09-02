import Foundation
import Testing
@testable import NotesOrganizerKit

@Suite("OrganizedNote")
struct OrganizedNoteTests {
    @Test("stores title, summary, and sections as given")
    func storesFields() {
        let note = OrganizedNote(
            title: "Groceries",
            summary: "What to pick up on the way home.",
            sections: [NoteSection(heading: "Produce", kind: .bullets, items: ["Milk", "Eggs"])]
        )
        #expect(note.title == "Groceries")
        #expect(note.summary == "What to pick up on the way home.")
        #expect(note.sections == [NoteSection(heading: "Produce", kind: .bullets, items: ["Milk", "Eggs"])])
    }

    @Test("defaults summary and sections to empty")
    func defaultsToEmpty() {
        let note = OrganizedNote(title: "Untitled")
        #expect(note.summary.isEmpty)
        #expect(note.sections.isEmpty)
    }

    @Test("equality is field-wise")
    func equality() {
        let a = OrganizedNote(title: "A", sections: [NoteSection(heading: "H", items: ["B"])])
        let b = OrganizedNote(title: "A", sections: [NoteSection(heading: "H", items: ["B"])])
        let c = OrganizedNote(title: "A", sections: [NoteSection(heading: "H", items: ["C"])])
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - The wire format

    @Test("survives a JSON round trip")
    func codableRoundTrip() throws {
        let note = OrganizedNote(
            title: "Kitchen quotes",
            summary: "Two quotes, one timeline.",
            sections: [
                NoteSection(heading: "Quotes", kind: .bullets, items: ["Bosch quoted 4200", "Miele quoted 5100"]),
                NoteSection(heading: "To Do", kind: .checklist, items: [NoteItem(text: "Call Priya", done: true)]),
            ]
        )

        let decoded = try JSONDecoder().decode(OrganizedNote.self, from: try JSONEncoder().encode(note))
        #expect(decoded == note)
    }

    @Test("decodes the shape the organize endpoint returns")
    func decodesTheWireShape() throws {
        let json = Data("""
        {"note":{"title":"Kitchen Renovation","summary":"","sections":[
          {"heading":"Quotes","kind":"bullets","items":[{"text":"Bosch quoted 4,200 for cabinets","done":false}]},
          {"heading":"To Do","kind":"checklist","items":[{"text":"Call the contractor back on Thursday","done":false},{"text":"Send Priya the floor plan","done":true}]}
        ]},"quota":{"used":1,"limit":5,"remaining":4,"month":"2026-09"},"plan":"free"}
        """.utf8)

        struct Envelope: Decodable { let note: OrganizedNote }
        let decoded = try JSONDecoder().decode(Envelope.self, from: json).note

        #expect(decoded == OrganizedNote(
            title: "Kitchen Renovation",
            sections: [
                NoteSection(heading: "Quotes", kind: .bullets, items: ["Bosch quoted 4,200 for cabinets"]),
                NoteSection(heading: "To Do", kind: .checklist, items: [
                    NoteItem(text: "Call the contractor back on Thursday"),
                    NoteItem(text: "Send Priya the floor plan", done: true),
                ]),
            ]
        ))
    }

    @Test("a response with no summary is a note, not a failure")
    func decodesMissingKeys() throws {
        let json = Data(#"{"title":"T","sections":[{"heading":"H"}]}"#.utf8)

        let decoded = try JSONDecoder().decode(OrganizedNote.self, from: json)
        #expect(decoded == OrganizedNote(title: "T", sections: [NoteSection(heading: "H")]))
        #expect(decoded.summary.isEmpty)
    }

    @Test("unknown keys are ignored")
    func ignoresUnknownKeys() throws {
        let json = Data(#"{"title":"T","actionItems":["gone"],"sections":[]}"#.utf8)

        #expect(try JSONDecoder().decode(OrganizedNote.self, from: json) == OrganizedNote(title: "T"))
    }
}

@Suite("NoteSection")
struct NoteSectionTests {
    @Test("equality is field-wise")
    func equality() {
        let a = NoteSection(heading: "H", kind: .bullets, items: ["1", "2"])
        let b = NoteSection(heading: "H", kind: .bullets, items: ["1", "2"])
        let c = NoteSection(heading: "H", kind: .bullets, items: ["1"])
        let d = NoteSection(heading: "H", kind: .checklist, items: ["1", "2"])
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }

    @Test("defaults to a bullet list")
    func defaultsToBullets() {
        #expect(NoteSection(heading: "H").kind == .bullets)
    }

    @Test("a kind this build doesn't know reads as bullets")
    func unknownKindFallsBackToBullets() throws {
        let json = Data(#"{"heading":"H","kind":"mermaid-diagram","items":["one"]}"#.utf8)

        let decoded = try JSONDecoder().decode(NoteSection.self, from: json)
        #expect(decoded == NoteSection(heading: "H", kind: .bullets, items: ["one"]))
    }

    @Test("a missing kind reads as bullets")
    func missingKindFallsBackToBullets() throws {
        let json = Data(#"{"heading":"H","items":["one"]}"#.utf8)

        #expect(try JSONDecoder().decode(NoteSection.self, from: json).kind == .bullets)
    }

    @Test("every kind decodes from its own name")
    func everyKindDecodes() throws {
        for kind in SectionKind.allCases {
            let json = Data(#"{"heading":"H","kind":"\#(kind.rawValue)","items":[]}"#.utf8)
            #expect(try JSONDecoder().decode(NoteSection.self, from: json).kind == kind)
        }
    }
}

@Suite("NoteItem")
struct NoteItemTests {
    @Test("a bare string decodes as an item that isn't done")
    func decodesFromAString() throws {
        let json = Data(#"["Call Priya", {"text":"Send the plan","done":true}]"#.utf8)

        let decoded = try JSONDecoder().decode([NoteItem].self, from: json)
        #expect(decoded == [NoteItem(text: "Call Priya"), NoteItem(text: "Send the plan", done: true)])
    }

    @Test("a string literal is an item that isn't done")
    func stringLiteral() {
        let item: NoteItem = "Call Priya"
        #expect(item == NoteItem(text: "Call Priya"))
        #expect(item.done == false)
    }

    @Test("a missing done reads as not done")
    func missingDoneIsFalse() throws {
        let json = Data(#"{"text":"Call Priya"}"#.utf8)

        #expect(try JSONDecoder().decode(NoteItem.self, from: json).done == false)
    }
}
