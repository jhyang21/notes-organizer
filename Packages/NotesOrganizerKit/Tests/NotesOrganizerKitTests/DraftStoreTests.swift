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

    // MARK: - The file slot

    /// A throwaway directory alongside the throwaway suite, so the file the
    /// store writes goes somewhere the test owns and takes away with it.
    private func withFileStore(_ body: (DraftStore, UserDefaults, URL) throws -> Void) throws {
        let suiteName = "DraftStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "DraftStoreTests-\(UUID().uuidString)")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        try body(DraftStore(defaults: defaults, directory: directory), defaults, directory)
    }

    @Test("a note saved to the file comes back whole")
    func fileNoteRoundTrips() throws {
        try withFileStore { store, _, directory in
            #expect(store.load() == nil)

            store.save(note)

            #expect(FileManager.default.fileExists(atPath: directory.appending(path: "organizedNote.v2.json").path))
            #expect(store.load() == note)
        }
    }

    @Test("clearing deletes the file")
    func clearRemovesTheFile() throws {
        try withFileStore { store, _, directory in
            store.save(note)
            store.clear()

            #expect(store.load() == nil)
            #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "organizedNote.v2.json").path))
        }
    }

    @Test("the file slot holds one note — the last one saved")
    func fileSlotHoldsOneNote() throws {
        try withFileStore { store, _, _ in
            store.save(note)
            store.save(OrganizedNote(title: "Groceries"))

            #expect(store.load()?.title == "Groceries")
        }
    }

    /// The note an earlier version left in the plist. Reading it once moves it
    /// into the protected file and takes it out of the defaults it should
    /// never have been in.
    @Test("a note left in defaults is moved into the file")
    func defaultsNoteMigratesToTheFile() throws {
        try withFileStore { store, defaults, directory in
            let data = try JSONEncoder().encode(note)
            defaults.set(data, forKey: "draft.organizedNote.v2")

            #expect(store.load() == note)
            #expect(defaults.data(forKey: "draft.organizedNote.v2") == nil)
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: "organizedNote.v2.json").path))
            // And it stays readable once the plist copy is gone.
            #expect(store.load() == note)
        }
    }

    @Test("a file that no longer decodes reads as empty, not as a crash")
    func undecodableFileReadsAsEmpty() throws {
        try withFileStore { store, _, directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("not a note".utf8).write(to: directory.appending(path: "organizedNote.v2.json"))

            #expect(store.load() == nil)
        }
    }

    @Test("the pre-v2 slot is swept up by the file store too")
    func fileStoreSweepsTheLegacyKey() throws {
        try withFileStore { store, defaults, _ in
            defaults.set(Data("old".utf8), forKey: "draft.organizedNote")

            #expect(store.load() == nil)
            #expect(defaults.data(forKey: "draft.organizedNote") == nil)
        }
    }
}
