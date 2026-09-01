import Foundation
import NotesOrganizerKit
import Testing
import UniformTypeIdentifiers

/// `NSItemProvider` and `NSExtensionItem` are ordinary objects a test can
/// build, so most of the loader is reachable here. What isn't: a real
/// `NSExtensionContext` — nothing below goes through one — and the file-URL
/// branch of the item decoder, because a provider asked for plain text from a
/// URL may hand back the URL's own string instead of the file's contents, so
/// the test would be asserting `NSItemProvider`'s coercion rules rather than
/// ours. Both need a device to answer properly.
@MainActor
@Suite("SharedTextLoader")
struct SharedTextLoaderTests {
    private func provider(_ text: String, as type: UTType = .plainText) -> NSItemProvider {
        NSItemProvider(item: text as NSString, typeIdentifier: type.identifier)
    }

    private func item(attachments: [NSItemProvider] = [], attributedText: String? = nil) -> NSExtensionItem {
        let extensionItem = NSExtensionItem()
        if !attachments.isEmpty {
            extensionItem.attachments = attachments
        }
        if let attributedText {
            extensionItem.attributedContentText = NSAttributedString(string: attributedText)
        }
        return extensionItem
    }

    // MARK: - Which identifier to ask for

    @Test("plain text is asked for first, then text, then whatever else conforms")
    func candidatesRunFromMostSpecificToLeast() {
        let candidates = SharedTextLoader.candidateIdentifiers(
            for: provider("Buy milk", as: .utf8PlainText)
        )

        #expect(candidates == [
            UTType.plainText.identifier,
            UTType.text.identifier,
            UTType.utf8PlainText.identifier,
        ])
    }

    @Test("a provider carrying nothing text-like offers no candidates")
    func nonTextProvidersAreSkipped() {
        let png = NSItemProvider(item: Data() as NSData, typeIdentifier: UTType.png.identifier)

        #expect(SharedTextLoader.candidateIdentifiers(for: png).isEmpty)
    }

    @Test("an identifier is never asked for twice")
    func candidatesAreDeduplicated() {
        let candidates = SharedTextLoader.candidateIdentifiers(for: provider("Buy milk"))

        #expect(candidates.first == UTType.plainText.identifier)
        #expect(Set(candidates).count == candidates.count)
    }

    // MARK: - Loading

    @Test("text loaded from an attachment is reported with the identifier it came from")
    func loadsFromAnAttachment() async {
        let log = makeLog()

        let loaded = await SharedTextLoader.load(from: [item(attachments: [provider("Buy milk")])], log: log)

        #expect(loaded.text == "Buy milk")
        #expect(loaded.chosenIdentifier == UTType.plainText.identifier)
        #expect(log.sharePayloads().first?.characterCount == 8)
    }

    @Test("an attachment registered as raw data is still text")
    func loadsTextFromData() async {
        let data = NSItemProvider(
            item: Data("Buy milk".utf8) as NSData,
            typeIdentifier: UTType.plainText.identifier
        )

        let loaded = await SharedTextLoader.load(from: [item(attachments: [data])], log: makeLog())

        #expect(loaded.text == "Buy milk")
    }

    @Test("the first attachment with something in it wins")
    func firstUsableAttachmentWins() async {
        let items = [item(attachments: [provider("First"), provider("Second")])]

        let loaded = await SharedTextLoader.load(from: items, log: makeLog())

        #expect(loaded.text == "First")
    }

    @Test("an attachment holding only whitespace is passed over")
    func whitespaceAttachmentFallsThrough() async {
        let items = [item(attachments: [provider("   \n ")], attributedText: "Buy milk")]

        let loaded = await SharedTextLoader.load(from: items, log: makeLog())

        #expect(loaded.text == "Buy milk")
        #expect(loaded.chosenIdentifier == LoadedShareText.attributedContentTextSource)
    }

    @Test("an item's own attributed text is the last resort")
    func fallsBackToAttributedContentText() async {
        let loaded = await SharedTextLoader.load(from: [item(attributedText: "Buy milk")], log: makeLog())

        #expect(loaded.text == "Buy milk")
        #expect(loaded.chosenIdentifier == LoadedShareText.attributedContentTextSource)
    }

    @Test("a payload with no text anywhere comes back empty, and says so in the log")
    func emptyPayloadIsRecorded() async {
        let log = makeLog()

        let loaded = await SharedTextLoader.load(from: [NSExtensionItem()], log: log)

        #expect(loaded.text.isEmpty)
        #expect(loaded.chosenIdentifier == nil)

        let payload = log.sharePayloads().first
        #expect(payload?.chosenIdentifier == nil)
        #expect(payload?.characterCount == 0)
    }

    // MARK: - The log

    @Test("what each provider registered is recorded before anything is loaded")
    func recordsTheWholePayload() async {
        let log = makeLog()
        let attachments = [provider("Buy milk"), provider("Ignored", as: .utf8PlainText)]

        _ = await SharedTextLoader.load(from: [item(attachments: attachments)], log: log)

        let payload = log.sharePayloads().first
        #expect(payload?.providerTypeIdentifiers == [
            [UTType.plainText.identifier],
            [UTType.utf8PlainText.identifier],
        ])
    }
}
