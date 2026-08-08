import Foundation
import Testing
@testable import NotesOrganizerKit

/// Stands in for the App Group suite. A lock rather than an actor so the
/// synchronous `DiagnosticsStorage` protocol still fits.
final class InMemoryDiagnosticsStorage: DiagnosticsStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        lock.withLock { values[key] }
    }

    func setData(_ data: Data?, forKey key: String) {
        lock.withLock {
            if let data {
                values[key] = data
            } else {
                values.removeValue(forKey: key)
            }
        }
    }
}

@Suite("DiagnosticsLog")
struct DiagnosticsLogTests {
    private func makeLog(limit: Int = DiagnosticsLog.defaultLimit) -> DiagnosticsLog {
        DiagnosticsLog(storage: InMemoryDiagnosticsStorage(), limit: limit)
    }

    // MARK: - Share payloads

    @Test("round-trips a share payload observation")
    func roundTripsSharePayload() {
        let log = makeLog()
        log.recordSharePayload(providerTypeIdentifiers: [["public.plain-text", "public.utf8-plain-text"]])
        log.completeLatestSharePayload(chosenIdentifier: "public.plain-text", characterCount: 1_234)

        let entries = log.sharePayloads()
        #expect(entries.count == 1)
        #expect(entries[0].providerTypeIdentifiers == [["public.plain-text", "public.utf8-plain-text"]])
        #expect(entries[0].chosenIdentifier == "public.plain-text")
        #expect(entries[0].characterCount == 1_234)
    }

    @Test("a payload recorded but never completed keeps its identifiers")
    func incompletePayloadSurvives() {
        let log = makeLog()
        log.recordSharePayload(providerTypeIdentifiers: [["public.url"]])

        let entries = log.sharePayloads()
        #expect(entries.count == 1)
        #expect(entries[0].chosenIdentifier == nil)
        #expect(entries[0].characterCount == 0)
    }

    @Test("completing with nothing recorded does nothing")
    func completingEmptyLogIsHarmless() {
        let log = makeLog()
        log.completeLatestSharePayload(chosenIdentifier: "public.text", characterCount: 10)
        #expect(log.sharePayloads().isEmpty)
    }

    @Test("completing only touches the newest entry")
    func completingTouchesNewestOnly() {
        let log = makeLog()
        log.recordSharePayload(providerTypeIdentifiers: [["first"]])
        log.completeLatestSharePayload(chosenIdentifier: "first-chosen", characterCount: 1)
        log.recordSharePayload(providerTypeIdentifiers: [["second"]])
        log.completeLatestSharePayload(chosenIdentifier: "second-chosen", characterCount: 2)

        let entries = log.sharePayloads()
        #expect(entries.map(\.chosenIdentifier) == ["second-chosen", "first-chosen"])
    }

    // MARK: - Ring buffer

    @Test("keeps entries newest first")
    func newestFirst() {
        let log = makeLog()
        for count in 1...3 {
            log.recordOrganizeTiming(source: .app, wordCount: count, duration: 1)
        }
        #expect(log.organizeTimings().map(\.wordCount) == [3, 2, 1])
    }

    @Test("trims to the limit, dropping the oldest")
    func trimsToLimit() {
        let log = makeLog(limit: 3)
        for count in 1...10 {
            log.recordOrganizeTiming(source: .shareExtension, wordCount: count, duration: 0.5)
        }

        let entries = log.organizeTimings()
        #expect(entries.count == 3)
        #expect(entries.map(\.wordCount) == [10, 9, 8])
    }

    @Test("trims each buffer independently")
    func buffersAreIndependent() {
        let log = makeLog(limit: 2)
        for index in 1...5 {
            log.recordSharePayload(providerTypeIdentifiers: [["type-\(index)"]])
            log.recordOrganizeTiming(source: .app, wordCount: index, duration: 0.1)
            log.recordEvent(source: .app, message: "event-\(index)")
        }

        #expect(log.sharePayloads().count == 2)
        #expect(log.organizeTimings().count == 2)
        #expect(log.events().count == 2)
        #expect(log.events().map(\.message) == ["event-5", "event-4"])
    }

    @Test("a limit below one still keeps one entry")
    func limitIsClamped() {
        let log = makeLog(limit: 0)
        log.recordEvent(source: .app, message: "first")
        log.recordEvent(source: .app, message: "second")

        #expect(log.events().map(\.message) == ["second"])
    }

    // MARK: - Encoding

    @Test("timings survive encoding to the nearest millisecond")
    func timingRoundTripsDuration() {
        let log = makeLog()
        log.recordOrganizeTiming(source: .shareExtension, wordCount: 412, duration: 6.25)

        let timing = log.organizeTimings().first
        #expect(timing?.source == .shareExtension)
        #expect(timing?.wordCount == 412)
        #expect(abs((timing?.duration ?? 0) - 6.25) < 0.001)
    }

    @Test("source encodes as app or extension")
    func sourceEncoding() throws {
        let encoded = try JSONEncoder().encode([DiagnosticsSource.app, .shareExtension])
        #expect(String(data: encoded, encoding: .utf8) == #"["app","extension"]"#)
    }

    @Test("unreadable stored data reads as an empty list")
    func corruptDataDegrades() {
        let storage = InMemoryDiagnosticsStorage()
        storage.setData(Data("not json".utf8), forKey: "diagnostics.events")
        let log = DiagnosticsLog(storage: storage)

        #expect(log.events().isEmpty)

        // And a write over the top still works.
        log.recordEvent(source: .app, message: "after")
        #expect(log.events().map(\.message) == ["after"])
    }

    @Test("clear empties every buffer")
    func clearEmptiesEverything() {
        let log = makeLog()
        log.recordSharePayload(providerTypeIdentifiers: [["public.text"]])
        log.recordOrganizeTiming(source: .app, wordCount: 1, duration: 1)
        log.recordEvent(source: .app, message: "hello")

        log.clear()

        #expect(log.sharePayloads().isEmpty)
        #expect(log.organizeTimings().isEmpty)
        #expect(log.events().isEmpty)
    }

    // MARK: - Storage

    @Test("a missing user defaults suite degrades to no-ops")
    func missingSuiteIsSafe() {
        let log = DiagnosticsLog(storage: UserDefaultsDiagnosticsStorage(defaults: nil))
        log.recordSharePayload(providerTypeIdentifiers: [["public.plain-text"]])
        log.completeLatestSharePayload(chosenIdentifier: "public.plain-text", characterCount: 5)
        log.recordOrganizeTiming(source: .app, wordCount: 5, duration: 1)
        log.clear()

        #expect(log.sharePayloads().isEmpty)
        #expect(log.organizeTimings().isEmpty)
    }

    @Test("persists through a real user defaults suite")
    func persistsThroughUserDefaults() throws {
        let suiteName = "DiagnosticsLogTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let writer = DiagnosticsLog(storage: UserDefaultsDiagnosticsStorage(defaults: defaults))
        writer.recordOrganizeTiming(source: .shareExtension, wordCount: 88, duration: 2.5)

        // A second instance over the same suite stands in for the app reading
        // what the extension wrote.
        let reader = DiagnosticsLog(storage: UserDefaultsDiagnosticsStorage(defaults: defaults))
        #expect(reader.organizeTimings().map(\.wordCount) == [88])
    }
}

@Suite("WordCounter")
struct WordCounterTests {
    @Test("counts whitespace-separated tokens")
    func countsTokens() {
        #expect(WordCounter.count("one two three") == 3)
        #expect(WordCounter.count("  padded   out  ") == 2)
        #expect(WordCounter.count("line\nbreaks\tcount") == 3)
        #expect(WordCounter.count("") == 0)
    }
}
