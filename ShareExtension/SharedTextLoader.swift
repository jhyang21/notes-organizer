import Foundation
import NotesOrganizerKit
import UniformTypeIdentifiers

/// The text a share handed us, and where it came from.
struct LoadedShareText: Sendable {
    /// The identifier recorded when the text came from the extension item's
    /// own `attributedContentText` rather than an attachment. Not a real UTI —
    /// it only ever appears in the diagnostics log.
    static let attributedContentTextSource = "(attributedContentText)"

    var text: String
    var chosenIdentifier: String?
}

/// Pulls text out of whatever a share sheet hands the extension.
///
/// Deliberately defensive: nobody has confirmed what Apple Notes puts in the
/// payload on iOS 26, so this tries the identifiers we expect, then anything
/// registered that conforms to text, then the item's own attributed text —
/// and records the whole payload either way, which is the M2 spike.
///
/// `@MainActor` throughout: `NSItemProvider` and `NSExtensionItem` never
/// leave the main actor, so nothing non-`Sendable` crosses an isolation
/// boundary. Only a `String?` comes back out of the load callback.
enum SharedTextLoader {
    @MainActor
    static func load(from items: [NSExtensionItem], log: DiagnosticsLog = .shared) async -> LoadedShareText {
        let providers = items.flatMap { $0.attachments ?? [] }

        // Recorded before any load runs: if a load hangs or the extension is
        // killed, the payload's shape is still on disk to look at later.
        log.recordSharePayload(providerTypeIdentifiers: providers.map(\.registeredTypeIdentifiers))

        for provider in providers {
            for identifier in candidateIdentifiers(for: provider) {
                guard let text = await loadText(from: provider, identifier: identifier),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                return finish(text: text, identifier: identifier, log: log)
            }
        }

        for item in items {
            guard let text = item.attributedContentText?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            return finish(text: text, identifier: LoadedShareText.attributedContentTextSource, log: log)
        }

        log.completeLatestSharePayload(chosenIdentifier: nil, characterCount: 0)
        return LoadedShareText(text: "", chosenIdentifier: nil)
    }

    /// `public.plain-text` first, then `public.text`, then anything else the
    /// provider registered that conforms to text. `hasItemConforming` matches
    /// by conformance, so a provider registering only
    /// `public.utf8-plain-text` still answers to the first entry.
    static func candidateIdentifiers(for provider: NSItemProvider) -> [String] {
        var ordered: [String] = []

        for preferred in [UTType.plainText.identifier, UTType.text.identifier]
        where provider.hasItemConformingToTypeIdentifier(preferred) {
            ordered.append(preferred)
        }

        for identifier in provider.registeredTypeIdentifiers
        where !ordered.contains(identifier) && (UTType(identifier)?.conforms(to: .text) ?? false) {
            ordered.append(identifier)
        }

        return ordered
    }

    // MARK: - Loading

    /// The completion closure is explicitly `@Sendable` so it doesn't inherit
    /// this method's main-actor isolation — the provider calls it on whatever
    /// queue it likes, and only a `String?` comes back across.
    @MainActor
    private static func loadText(from provider: NSItemProvider, identifier: String) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { @Sendable item, _ in
                continuation.resume(returning: SharedTextLoader.text(from: item))
            }
        }
    }

    /// A provider can hand back a string, an attributed string, raw data, or
    /// a file URL for the same identifier. All four mean text here.
    private static func text(from item: NSSecureCoding?) -> String? {
        switch item as Any {
        case let string as String:
            return string
        case let attributed as NSAttributedString:
            return attributed.string
        case let data as Data:
            return String(data: data, encoding: .utf8)
        case let url as URL where url.isFileURL:
            return try? String(contentsOf: url, encoding: .utf8)
        default:
            return nil
        }
    }

    private static func finish(text: String, identifier: String, log: DiagnosticsLog) -> LoadedShareText {
        log.completeLatestSharePayload(chosenIdentifier: identifier, characterCount: text.count)
        return LoadedShareText(text: text, chosenIdentifier: identifier)
    }
}
