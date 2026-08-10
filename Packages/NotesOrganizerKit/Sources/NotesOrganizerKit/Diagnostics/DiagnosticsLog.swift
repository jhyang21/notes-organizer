import Foundation

/// Which process produced an entry. The share extension and the app both
/// write to the same App Group suite, so every entry says where it came from.
public enum DiagnosticsSource: String, Codable, Sendable {
    case app
    case shareExtension = "extension"

    public var displayName: String {
        switch self {
        case .app: "App"
        case .shareExtension: "Extension"
        }
    }
}

/// What one share handed the extension. The point of recording this is the
/// M2 question nobody can answer from a Windows machine: which type
/// identifiers does Apple Notes actually put on the pasteboard in iOS 26, and
/// which one carries the text.
public struct SharePayloadObservation: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    /// One entry per `NSItemProvider`, holding that provider's full
    /// `registeredTypeIdentifiers`.
    public var providerTypeIdentifiers: [[String]]
    /// The identifier the text was loaded from, or `nil` while the load is
    /// still in flight or if every attempt failed.
    public var chosenIdentifier: String?
    public var characterCount: Int

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        providerTypeIdentifiers: [[String]],
        chosenIdentifier: String? = nil,
        characterCount: Int = 0
    ) {
        self.id = id
        self.timestamp = timestamp
        self.providerTypeIdentifiers = providerTypeIdentifiers
        self.chosenIdentifier = chosenIdentifier
        self.characterCount = characterCount
    }
}

/// How long one organize took, and on how much text. Source, word count, and
/// duration are all there is to record: one organizer runs every note, so
/// there is nothing to tell apart.
public struct OrganizeTiming: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var source: DiagnosticsSource
    public var wordCount: Int
    public var duration: TimeInterval

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: DiagnosticsSource,
        wordCount: Int,
        duration: TimeInterval
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.wordCount = wordCount
        self.duration = duration
    }
}

/// A one-line note about something that happened, for the questions timings
/// and payloads don't answer — "did the share sheet open", "did organizing
/// throw". Deliberately unstructured: this is a beta diagnostic, not
/// analytics.
public struct DiagnosticsEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var source: DiagnosticsSource
    public var message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), source: DiagnosticsSource, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.message = message
    }
}

/// A small shared log the app and the share extension both write to, so the
/// app's Diagnostics screen can show what happened inside the extension —
/// which has no UI of its own once it closes.
///
/// Three ring buffers, newest first, each capped at `limit` entries. Writes
/// are best effort: nothing here is worth failing a user's note over, so an
/// encoding failure or a missing App Group suite is silently a no-op.
public struct DiagnosticsLog: Sendable {
    public static let defaultLimit = 20

    /// The instance both targets use.
    public static let shared = DiagnosticsLog(
        storage: UserDefaultsDiagnosticsStorage(defaults: AppGroup.defaults)
    )

    private enum Key {
        static let sharePayloads = "diagnostics.sharePayloads"
        static let organizeTimings = "diagnostics.organizeTimings"
        static let events = "diagnostics.events"
    }

    private let storage: DiagnosticsStorage
    private let limit: Int

    public init(storage: DiagnosticsStorage, limit: Int = DiagnosticsLog.defaultLimit) {
        self.storage = storage
        self.limit = max(1, limit)
    }

    // MARK: - Share payloads

    /// Records what arrived before anything is loaded, so a load that hangs
    /// or crashes still leaves evidence of what the payload looked like.
    /// `completeLatestSharePayload` fills in the rest.
    public func recordSharePayload(providerTypeIdentifiers: [[String]]) {
        prepend(
            SharePayloadObservation(providerTypeIdentifiers: providerTypeIdentifiers),
            forKey: Key.sharePayloads
        )
    }

    /// Fills in the identifier the text came from and how much text it was.
    /// No-op if nothing was recorded first.
    public func completeLatestSharePayload(chosenIdentifier: String?, characterCount: Int) {
        var entries: [SharePayloadObservation] = load(forKey: Key.sharePayloads)
        guard !entries.isEmpty else { return }
        entries[0].chosenIdentifier = chosenIdentifier
        entries[0].characterCount = characterCount
        save(entries, forKey: Key.sharePayloads)
    }

    public func sharePayloads() -> [SharePayloadObservation] {
        load(forKey: Key.sharePayloads)
    }

    // MARK: - Organize timings

    public func recordOrganizeTiming(source: DiagnosticsSource, wordCount: Int, duration: TimeInterval) {
        prepend(
            OrganizeTiming(source: source, wordCount: wordCount, duration: duration),
            forKey: Key.organizeTimings
        )
    }

    public func organizeTimings() -> [OrganizeTiming] {
        load(forKey: Key.organizeTimings)
    }

    // MARK: - Events

    public func recordEvent(source: DiagnosticsSource, message: String) {
        prepend(DiagnosticsEvent(source: source, message: message), forKey: Key.events)
    }

    public func events() -> [DiagnosticsEvent] {
        load(forKey: Key.events)
    }

    // MARK: - Housekeeping

    public func clear() {
        storage.setData(nil, forKey: Key.sharePayloads)
        storage.setData(nil, forKey: Key.organizeTimings)
        storage.setData(nil, forKey: Key.events)
    }

    // MARK: - Ring buffer

    private func prepend<Entry: Codable>(_ entry: Entry, forKey key: String) {
        var entries: [Entry] = load(forKey: key)
        entries.insert(entry, at: 0)
        save(Array(entries.prefix(limit)), forKey: key)
    }

    private func load<Entry: Codable>(forKey key: String) -> [Entry] {
        guard let data = storage.data(forKey: key) else { return [] }
        // Unreadable data means an older encoding or a partial write; an
        // empty list is a better answer than a crash in a diagnostics screen.
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func save<Entry: Codable>(_ entries: [Entry], forKey key: String) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        storage.setData(data, forKey: key)
    }
}
