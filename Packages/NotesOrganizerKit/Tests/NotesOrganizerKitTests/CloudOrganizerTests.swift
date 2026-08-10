import Foundation
import Testing
@testable import NotesOrganizerKit

/// Holds the request the organizer would have sent, and answers with whatever
/// the test decided. A class with a lock rather than an actor so it fits the
/// synchronous shape of a `Transport` closure's caller.
private final class TransportSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var callCount: Int { lock.withLock { requests.count } }
    var lastRequest: URLRequest? { lock.withLock { requests.last } }

    /// Answers every call with `status` and `json`.
    func responding(status: Int, json: String) -> CloudOrganizer.Transport {
        { request in
            self.record(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (Data(json.utf8), response)
        }
    }

    /// Answers every call by throwing.
    func failing<Failure: Error & Sendable>(with error: Failure) -> CloudOrganizer.Transport {
        { request in
            self.record(request)
            throw error
        }
    }

    private func record(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }
}

/// The body the organizer sent, read back as a type rather than a
/// dictionary — `[String: Any]` isn't `Sendable` and can't cross into an
/// `#expect`.
private struct SentRequestBody: Decodable {
    let text: String
    let appUserId: String
    let clientVersion: String
}

@Suite("CloudOrganizer")
struct CloudOrganizerTests {
    private let config = CloudConfig(
        functionsURL: URL(string: "https://example-project.supabase.co/functions/v1")!,
        anonKey: "test-publishable-key"
    )

    private let transcript = "Talked to Priya about the kitchen quotes and the timeline for August."

    private let successJSON = """
    {
      "note": {
        "title": "Kitchen  quotes",
        "sections": [
          { "heading": "Quotes", "bullets": ["Bosch quoted 4200", "", "Bosch quoted 4200"] }
        ],
        "actionItems": ["Call Priya"]
      },
      "quota": { "used": 2, "limit": 5, "remaining": 3, "month": "2026-08" },
      "plan": "free"
    }
    """

    /// A store over a throwaway suite, plus its cleanup.
    private func makeStore() throws -> (EntitlementStore, String, UserDefaults) {
        let suiteName = "CloudOrganizerTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (EntitlementStore(defaults: defaults), suiteName, defaults)
    }

    private func makeOrganizer(store: EntitlementStore, transport: @escaping CloudOrganizer.Transport) -> CloudOrganizer {
        CloudOrganizer(config: config, store: store, clientVersion: "1.2 (34)", transport: transport)
    }

    // MARK: - Success

    @Test("a 200 comes back sanitized and records the quota the server reported")
    func decodesAndRecordsOnSuccess() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let spy = TransportSpy()
        let organizer = makeOrganizer(store: store, transport: spy.responding(status: 200, json: successJSON))

        let note = try await organizer.organize(transcript)

        // Sanitized on the way in: collapsed whitespace, no blank bullet, no
        // repeat of the line before it.
        #expect(note.title == "Kitchen quotes")
        #expect(note.sections == [NoteSection(heading: "Quotes", bullets: ["Bosch quoted 4200"])])
        #expect(note.actionItems == ["Call Priya"])

        let state = try #require(store.planState())
        #expect(state.cloudUsed == 2)
        #expect(state.cloudLimit == 5)
        #expect(state.monthKey == "2026-08")
        #expect(state.isPro == false)
    }

    @Test("a pro plan in the response is mirrored into the store")
    func recordsProPlan() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let json = """
        {
          "note": { "title": "T", "sections": [], "actionItems": [] },
          "quota": { "used": 9, "limit": 5, "remaining": 0, "month": "2026-08" },
          "plan": "pro"
        }
        """
        let organizer = makeOrganizer(store: store, transport: TransportSpy().responding(status: 200, json: json))

        _ = try await organizer.organize(transcript)

        #expect(store.isPro())
    }

    // MARK: - Request shape

    @Test("posts the transcript to TidyNote's function with both auth headers")
    func sendsTheExpectedRequest() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let spy = TransportSpy()
        let organizer = makeOrganizer(store: store, transport: spy.responding(status: 200, json: successJSON))

        _ = try await organizer.organize(transcript)

        let request = try #require(spy.lastRequest)
        // The name matters: the project hosts another app's functions too.
        #expect(request.url?.absoluteString == "https://example-project.supabase.co/functions/v1/tidynote_organize")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-publishable-key")
        #expect(request.value(forHTTPHeaderField: "apikey") == "test-publishable-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try JSONDecoder().decode(SentRequestBody.self, from: try #require(request.httpBody))
        #expect(body.text == transcript)
        #expect(body.clientVersion == "1.2 (34)")
        #expect(body.appUserId == store.appUserID())
    }

    @Test("nothing worth organizing never reaches the network")
    func emptyTranscriptShortCircuits() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let spy = TransportSpy()
        let organizer = makeOrganizer(store: store, transport: spy.responding(status: 200, json: successJSON))

        await #expect(throws: OrganizeFailure.emptyTranscript) {
            try await organizer.organize("hi")
        }
        #expect(spy.callCount == 0)
    }

    // MARK: - Failures

    @Test("an exhausted quota is a wall, and the server's counts are kept")
    func mapsQuotaExhausted() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let json = """
        {
          "error": { "code": "quota_exhausted" },
          "quota": { "used": 5, "limit": 5, "remaining": 0, "month": "2026-08" }
        }
        """
        let organizer = makeOrganizer(store: store, transport: TransportSpy().responding(status: 429, json: json))

        await #expect(throws: OrganizeFailure.cloudQuotaExhausted) {
            try await organizer.organize(transcript)
        }

        let state = try #require(store.planState())
        #expect(state.cloudUsed == 5)
        #expect(state.monthKey == "2026-08")
    }

    @Test("being rate limited is a wait, not a wall")
    func mapsRateLimited() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let organizer = makeOrganizer(
            store: store,
            transport: TransportSpy().responding(status: 429, json: #"{"error":{"code":"rate_limited"}}"#)
        )

        let failure = await capture { _ = try await organizer.organize(transcript) }
        guard case .cloudUnavailable = try #require(failure) else {
            Issue.record("expected cloudUnavailable, got \(String(describing: failure))")
            return
        }
        // A rate limit must never be mistaken for the month running out.
        #expect(store.planState() == nil)
    }

    /// Both paths read one envelope, so the text path maps these the same way
    /// the voice path does — a 422 on typed text is the server agreeing there
    /// was nothing there worth a note.
    @Test("a 422 is the server saying there was nothing to organize")
    func mapsNothingToOrganize() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let organizer = makeOrganizer(store: store, transport: TransportSpy().responding(status: 422, json: "{}"))

        await #expect(throws: OrganizeFailure.emptyTranscript) {
            try await organizer.organize(transcript)
        }
    }

    @Test("a 413 is a payload the endpoint won't take")
    func mapsPayloadTooLarge() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let organizer = makeOrganizer(store: store, transport: TransportSpy().responding(status: 413, json: "{}"))

        await #expect(throws: OrganizeFailure.audioTooLarge) {
            try await organizer.organize(transcript)
        }
    }

    @Test("a server error surfaces as the service having a problem")
    func mapsServerError() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let organizer = makeOrganizer(store: store, transport: TransportSpy().responding(status: 500, json: "{}"))

        let failure = await capture { _ = try await organizer.organize(transcript) }
        guard case .cloudUnavailable = try #require(failure) else {
            Issue.record("expected cloudUnavailable, got \(String(describing: failure))")
            return
        }
    }

    @Test("a 200 that isn't a note surfaces as the service having a problem")
    func mapsUndecodableSuccess() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let organizer = makeOrganizer(store: store, transport: TransportSpy().responding(status: 200, json: #"{"hello":"world"}"#))

        let failure = await capture { _ = try await organizer.organize(transcript) }
        guard case .cloudUnavailable = try #require(failure) else {
            Issue.record("expected cloudUnavailable, got \(String(describing: failure))")
            return
        }
        #expect(store.planState() == nil)
    }

    @Test("no connection reads as offline")
    func mapsOffline() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let organizer = makeOrganizer(
            store: store,
            transport: TransportSpy().failing(with: URLError(.notConnectedToInternet))
        )

        await #expect(throws: OrganizeFailure.networkUnavailable) {
            try await organizer.organize(transcript)
        }
    }

    @Test("a timeout reads as offline too — both mean try again later")
    func mapsTimeout() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let organizer = makeOrganizer(store: store, transport: TransportSpy().failing(with: URLError(.timedOut)))

        await #expect(throws: OrganizeFailure.networkUnavailable) {
            try await organizer.organize(transcript)
        }
    }

    @Test("cancellation passes through untouched, however it arrives")
    func rethrowsCancellation() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let cancelled = makeOrganizer(store: store, transport: TransportSpy().failing(with: CancellationError()))
        await #expect(throws: CancellationError.self) {
            try await cancelled.organize(transcript)
        }

        // URLSession reports a cancelled task as a `URLError`, which must not
        // be mistaken for the user being offline.
        let cancelledTask = makeOrganizer(store: store, transport: TransportSpy().failing(with: URLError(.cancelled)))
        await #expect(throws: CancellationError.self) {
            try await cancelledTask.organize(transcript)
        }
    }

    /// `#expect(throws:)` can't hand back the value it caught, and these tests
    /// need to look inside an associated value.
    private func capture(_ body: () async throws -> Void) async -> OrganizeFailure? {
        do {
            try await body()
            return nil
        } catch let failure as OrganizeFailure {
            return failure
        } catch {
            return nil
        }
    }
}
