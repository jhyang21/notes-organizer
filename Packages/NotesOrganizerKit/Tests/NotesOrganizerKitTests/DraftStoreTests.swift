import Foundation
import Testing
@testable import NotesOrganizerKit

@Suite("DraftStore")
struct DraftStoreTests {
    private let note = OrganizedNote(
        title: "Kitchen quotes",
        sections: [NoteSection(heading: "Quotes", kind: .bullets, items: ["Bosch quoted 4,200"])]
    )

    /// A throwaway suite per test, removed afterwards, so nothing leaks into
    /// the next test or the machine running it.
    private func withStore(_ body: (DraftStore, UserDefaults) throws -> Void) throws {
        let suiteName = "DraftStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(DraftStore(defaults: defaults), defaults)
    }

    @Test("a saved note comes back whole")
    func noteRoundTrips() throws {
        try withStore { store, _ in
            #expect(store.load() == nil)

            store.save(note)

            #expect(store.load() == note)
        }
    }

    @Test("the slot holds one note — the last one saved")
    func savingOverwritesTheSlot() throws {
        try withStore { store, _ in
            store.save(note)
            store.save(OrganizedNote(title: "Groceries"))

            #expect(store.load()?.title == "Groceries")
        }
    }

    @Test("clearing leaves nothing to restore")
    func clearEmptiesTheSlot() throws {
        try withStore { store, _ in
            store.save(note)
            store.clear()

            #expect(store.load() == nil)
        }
    }

    @Test("a slot that no longer decodes reads as empty, not as a crash")
    func undecodableDataReadsAsEmpty() throws {
        try withStore { store, defaults in
            defaults.set(Data("not a note".utf8), forKey: "draft.organizedNote.v2")

            #expect(store.load() == nil)
        }
    }

    @Test("a draft left by the old note shape is ignored and swept up")
    func legacyDraftIsIgnored() throws {
        try withStore { store, defaults in
            let legacy = #"{"title":"Old","sections":[{"heading":"H","bullets":["b"]}],"actionItems":["a"]}"#
            defaults.set(Data(legacy.utf8), forKey: "draft.organizedNote")

            #expect(store.load() == nil)
            #expect(defaults.data(forKey: "draft.organizedNote") == nil)
        }
    }

    @Test("a build without the App Group degrades to no-ops")
    func missingSuiteIsSafe() {
        let store = DraftStore(defaults: nil)

        store.save(note)
        // Clearing a slot that was never written must be as harmless as
        // clearing one that was.
        store.clear()

        #expect(store.load() == nil)
    }
}
