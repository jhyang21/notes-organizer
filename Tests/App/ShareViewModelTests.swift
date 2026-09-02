import Foundation
import NotesOrganizerKit
import Testing
import UniformTypeIdentifiers

/// `ShareViewModel` and `SharedTextLoader` are compiled into this bundle
/// rather than imported: an app extension is not a module, so there is
/// nothing to import.
@MainActor
@Suite("ShareViewModel")
struct ShareViewModelTests {
    private let note = OrganizedNote(
        title: "Kitchen quotes",
        sections: [NoteSection(heading: "Quotes", kind: .bullets, items: ["Bosch quoted 4,200"])]
    )

    /// What a share sheet hands the extension when the user selected text.
    private func items(_ text: String) -> [NSExtensionItem] {
        let item = NSExtensionItem()
        item.attachments = [NSItemProvider(item: text as NSString, typeIdentifier: UTType.plainText.identifier)]
        return [item]
    }

    private func makeViewModel(
        organizer: some NoteOrganizing & VoiceOrganizing,
        store: EntitlementStore
    ) -> ShareViewModel {
        ShareViewModel(routing: OrganizeRouting(store: store, cloud: organizer), log: makeLog())
    }

    // MARK: - The happy path

    @Test("shared text is organized and previewed")
    func organizesSharedText() async throws {
        let defaults = try EphemeralDefaults()
        let organizer = MockOrganizer(result: note)
        let model = makeViewModel(organizer: organizer, store: makeStore(defaults))

        await model.start(with: items("Bosch quoted 4,200 for cabinets"))

        #expect(model.state == .preview(note))
        #expect(await organizer.receivedTranscripts == ["Bosch quoted 4,200 for cabinets"])
        #expect(model.originalText == "Bosch quoted 4,200 for cabinets")
    }

    @Test("the wait says how much text is being organized")
    func reportsTheWordCountWhileWaiting() async throws {
        let defaults = try EphemeralDefaults()
        let model = makeViewModel(organizer: SlowOrganizer(), store: makeStore(defaults))

        let run = Task { await model.start(with: items("one two three four")) }
        defer { run.cancel() }

        try await waitUntil("the organizing state") { model.state == .organizing(wordCount: 4) }
    }

    // MARK: - Nothing to organize

    @Test("a share with no text in it says so")
    func emptyShareIsNothingToOrganize() async throws {
        let defaults = try EphemeralDefaults()
        let organizer = MockOrganizer(result: note)
        let model = makeViewModel(organizer: organizer, store: makeStore(defaults))

        await model.start(with: [NSExtensionItem()])

        #expect(model.state == .nothingToOrganize)
        #expect(await organizer.receivedTranscripts.isEmpty)
    }

    @Test("whitespace is not text")
    func whitespaceOnlyShareIsNothingToOrganize() async throws {
        let defaults = try EphemeralDefaults()
        let organizer = MockOrganizer(result: note)
        let model = makeViewModel(organizer: organizer, store: makeStore(defaults))

        await model.start(with: items("   \n  "))

        #expect(model.state == .nothingToOrganize)
        #expect(await organizer.receivedTranscripts.isEmpty)
    }

    // MARK: - Walls

    @Test("an unanswered first run points at the app instead of sending anything")
    func consentBlocksTheExtension() async throws {
        let defaults = try EphemeralDefaults()
        let organizer = MockOrganizer(result: note)
        let model = makeViewModel(organizer: organizer, store: makeStore(defaults, consentGranted: false))

        await model.start(with: items("Bosch quoted 4,200 for cabinets"))

        #expect(model.state == .unavailable(.cloudConsentNeeded))
        #expect(await organizer.receivedTranscripts.isEmpty)
    }

    @Test("a spent quota is a wall here too")
    func quotaBlocksTheExtension() async throws {
        let defaults = try EphemeralDefaults()
        let organizer = MockOrganizer(result: note)
        let model = makeViewModel(organizer: organizer, store: makeStore(defaults, remaining: 0))

        await model.start(with: items("Bosch quoted 4,200 for cabinets"))

        #expect(model.state == .unavailable(.cloudQuotaExhausted))
        #expect(await organizer.receivedTranscripts.isEmpty)
    }

    // MARK: - Failing and retrying

    @Test("a failed organize keeps the text and retries with it")
    func retryReusesTheSharedText() async throws {
        let defaults = try EphemeralDefaults()
        let organizer = MockOrganizer(error: .networkUnavailable)
        let model = makeViewModel(organizer: organizer, store: makeStore(defaults))

        await model.start(with: items("Bosch quoted 4,200 for cabinets"))
        #expect(model.state == .unavailable(.networkUnavailable))
        // The escape hatch depends on this: a failure never leaves the user
        // holding nothing.
        #expect(model.originalText == "Bosch quoted 4,200 for cabinets")

        await organizer.setOutcome(.success(note))
        await model.retry()

        #expect(model.state == .preview(note))
        #expect(await organizer.receivedTranscripts.count == 2)
    }

    @Test("retrying with nothing to retry says so rather than sending an empty tidy")
    func retryWithoutTextIsNothingToOrganize() async throws {
        let defaults = try EphemeralDefaults()
        let organizer = MockOrganizer(result: note)
        let model = makeViewModel(organizer: organizer, store: makeStore(defaults))

        await model.retry()

        #expect(model.state == .nothingToOrganize)
        #expect(await organizer.receivedTranscripts.isEmpty)
    }
}
