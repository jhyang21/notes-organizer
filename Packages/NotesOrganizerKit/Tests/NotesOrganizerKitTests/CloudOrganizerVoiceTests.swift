import Foundation
import Testing
@testable import NotesOrganizerKit

/// Same job as the spy in `CloudOrganizerTests`: hold the request the
/// organizer would have sent, answer with whatever the test decided, and open
/// no socket doing it.
private final class VoiceTransportSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var callCount: Int { lock.withLock { requests.count } }
    var lastRequest: URLRequest? { lock.withLock { requests.last } }

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

@Suite("CloudOrganizer voice")
struct CloudOrganizerVoiceTests {
    private let config = CloudConfig(
        functionsURL: URL(string: "https://example-project.supabase.co/functions/v1")!,
        anonKey: "test-publishable-key"
    )

    /// Bytes no text encoding would survive, so a body that keeps them proves
    /// the upload is binary-safe.
    private let audioBytes = Data([0x00, 0x20, 0xFF, 0x0D, 0x0A, 0x2D, 0x2D, 0x80, 0x7F])

    private let successJSON = """
    {
      "note": {
        "title": "Kitchen  quotes",
        "sections": [
          { "heading": "Quotes", "bullets": ["Bosch quoted 4200", ""] }
        ],
        "actionItems": ["Call Priya"]
      },
      "quota": { "used": 2, "limit": 5, "remaining": 3, "month": "2026-08" },
      "plan": "free",
      "transcript": "so I talked to Priya about the kitchen quotes"
    }
    """

    // MARK: - Fixtures

    private func makeStore() throws -> (EntitlementStore, String, UserDefaults) {
        let suiteName = "CloudOrganizerVoiceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (EntitlementStore(defaults: defaults), suiteName, defaults)
    }

    private func makeOrganizer(store: EntitlementStore, transport: @escaping CloudOrganizer.Transport) -> CloudOrganizer {
        CloudOrganizer(config: config, store: store, clientVersion: "1.2 (34)", transport: transport)
    }

    /// A real file on disk, since the organizer reads one.
    private func makeRecording(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tidynote-test-\(UUID().uuidString).m4a")
        try bytes.write(to: url)
        return url
    }

    // MARK: - Request shape

    @Test("posts the recording to TidyNote's function with both auth headers")
    func sendsTheExpectedRequest() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recording = try makeRecording(audioBytes)
        defer { try? FileManager.default.removeItem(at: recording) }

        let spy = VoiceTransportSpy()
        let organizer = makeOrganizer(store: store, transport: spy.responding(status: 200, json: successJSON))

        _ = try await organizer.organize(audioAt: recording, durationSeconds: 42.4, locale: Locale(identifier: "en_US"))

        let request = try #require(spy.lastRequest)
        #expect(request.url?.absoluteString == "https://example-project.supabase.co/functions/v1/tidynote_organize")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-publishable-key")
        #expect(request.value(forHTTPHeaderField: "apikey") == "test-publishable-key")
        // Longer than the text path's ninety: the server transcribes first.
        #expect(request.timeoutInterval == 150)

        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        #expect(!boundary.isEmpty)

        let raw = try #require(request.httpBody)
        let body = try text(raw)
        #expect(body.hasPrefix("--\(boundary)\r\n"))
        #expect(body.hasSuffix("--\(boundary)--\r\n"))

        #expect(field("appUserId", in: body) == store.appUserID())
        #expect(field("clientVersion", in: body) == "1.2 (34)")
        // Whole seconds, rounded — the server wants a hint, not a measurement.
        #expect(field("durationSeconds", in: body) == "42")
        #expect(field("locale", in: body) == "en-US")

        // The recording itself, byte for byte, under the name and type the
        // endpoint expects.
        let marker = Data("Content-Disposition: form-data; name=\"audio\"; filename=\"capture.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8)
        let start = try #require(raw.range(of: marker)).upperBound
        #expect(raw[start..<(start + audioBytes.count)] == audioBytes)
    }

    @Test("a locale with nothing to say is left out rather than sent empty")
    func omitsEmptyLocale() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recording = try makeRecording(audioBytes)
        defer { try? FileManager.default.removeItem(at: recording) }

        let spy = VoiceTransportSpy()
        let organizer = makeOrganizer(store: store, transport: spy.responding(status: 200, json: successJSON))

        _ = try await organizer.organize(audioAt: recording, durationSeconds: 10, locale: Locale(identifier: ""))

        let body = try text(try #require(spy.lastRequest?.httpBody))
        // Either there's no locale part at all, or it carries something the
        // server can act on — never a blank one for it to puzzle over.
        if let sent = field("locale", in: body) {
            #expect(!sent.isEmpty)
        }
    }

    @Test("a duration that means nothing goes out as zero")
    func normalizesNonsenseDuration() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recording = try makeRecording(audioBytes)
        defer { try? FileManager.default.removeItem(at: recording) }

        let spy = VoiceTransportSpy()
        let organizer = makeOrganizer(store: store, transport: spy.responding(status: 200, json: successJSON))

        _ = try await organizer.organize(audioAt: recording, durationSeconds: .nan, locale: Locale(identifier: "en_US"))

        let body = try text(try #require(spy.lastRequest?.httpBody))
        #expect(field("durationSeconds", in: body) == "0")
    }

    @Test("a recording that isn't there never reaches the network")
    func missingFileShortCircuits() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let spy = VoiceTransportSpy()
        let organizer = makeOrganizer(store: store, transport: spy.responding(status: 200, json: successJSON))
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("tidynote-missing-\(UUID().uuidString).m4a")

        let failure = await capture {
            _ = try await organizer.organize(audioAt: missing, durationSeconds: 12, locale: Locale(identifier: "en_US"))
        }
        guard case .cloudUnavailable = try #require(failure) else {
            Issue.record("expected cloudUnavailable, got \(String(describing: failure))")
            return
        }
        #expect(spy.callCount == 0)
    }

    // MARK: - Success

    @Test("a 200 comes back sanitized and records the quota the server reported")
    func decodesAndRecordsOnSuccess() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recording = try makeRecording(audioBytes)
        defer { try? FileManager.default.removeItem(at: recording) }

        let organizer = makeOrganizer(store: store, transport: VoiceTransportSpy().responding(status: 200, json: successJSON))

        let note = try await organizer.organize(audioAt: recording, durationSeconds: 42, locale: Locale(identifier: "en_US"))

        #expect(note.title == "Kitchen quotes")
        #expect(note.sections == [NoteSection(heading: "Quotes", bullets: ["Bosch quoted 4200"])])
        #expect(note.actionItems == ["Call Priya"])

        let state = try #require(store.planState())
        #expect(state.cloudUsed == 2)
        #expect(state.cloudLimit == 5)
        #expect(state.monthKey == "2026-08")
        #expect(state.isPro == false)
    }

    @Test("a 200 with no transcript in it is still a note")
    func toleratesMissingTranscript() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recording = try makeRecording(audioBytes)
        defer { try? FileManager.default.removeItem(at: recording) }

        let json = """
        {
          "note": { "title": "T", "sections": [], "actionItems": [] },
          "quota": { "used": 1, "limit": 5, "remaining": 4, "month": "2026-08" },
          "plan": "pro"
        }
        """
        let organizer = makeOrganizer(store: store, transport: VoiceTransportSpy().responding(status: 200, json: json))

        let note = try await organizer.organize(audioAt: recording, durationSeconds: 42, locale: Locale(identifier: "en_US"))

        #expect(note.title == "T")
        #expect(store.isPro())
    }

    // MARK: - Failures

    @Test("an exhausted quota is a wall, and the server's counts are kept")
    func mapsQuotaExhausted() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recording = try makeRecording(audioBytes)
        defer { try? FileManager.default.removeItem(at: recording) }

        let json = """
        {
          "error": { "code": "quota_exhausted" },
          "quota": { "used": 5, "limit": 5, "remaining": 0, "month": "2026-08" }
        }
        """
        let organizer = makeOrganizer(store: store, transport: VoiceTransportSpy().responding(status: 429, json: json))

        await #expect(throws: OrganizeFailure.cloudQuotaExhausted) {
            try await organizer.organize(audioAt: recording, durationSeconds: 42, locale: Locale(identifier: "en_US"))
        }

        let state = try #require(store.planState())
        #expect(state.cloudUsed == 5)
        #expect(state.monthKey == "2026-08")
    }

    @Test("being rate limited is a wait, not a wall")
    func mapsRateLimited() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recording = try makeRecording(audioBytes)
        defer { try? FileManager.default.removeItem(at: recording) }

        let organizer = makeOrganizer(
            store: store,
            transport: VoiceTransportSpy().responding(status: 429, json: #"{"error":{"code":"rate_limited"}}"#)
        )

        let failure = await capture {
            _ = try await organizer.organize(audioAt: recording, durationSeconds: 42, locale: Locale(identifier: "en_US"))
        }
        guard case .cloudUnavailable = try #require(failure) else {
            Issue.record("expected cloudUnavailable, got \(String(describing: failure))")
            return
        }
        #expect(store.planState() == nil)
    }

    /// 413 is a recording the endpoint won't take, 422 is one with nothing
    /// audible in it, 500 is the service. All three read as "something went
    /// wrong" until M15 gives the first two their own copy.
    @Test("statuses the voice path can meet all read as the service having a problem", arguments: [413, 422, 500])
    func mapsUnexpectedStatuses(status: Int) async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recording = try makeRecording(audioBytes)
        defer { try? FileManager.default.removeItem(at: recording) }

        let organizer = makeOrganizer(store: store, transport: VoiceTransportSpy().responding(status: status, json: "{}"))

        let failure = await capture {
            _ = try await organizer.organize(audioAt: recording, durationSeconds: 42, locale: Locale(identifier: "en_US"))
        }
        guard case .cloudUnavailable = try #require(failure) else {
            Issue.record("expected cloudUnavailable for \(status), got \(String(describing: failure))")
            return
        }
        #expect(store.planState() == nil)
    }

    @Test("no connection reads as offline")
    func mapsOffline() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recording = try makeRecording(audioBytes)
        defer { try? FileManager.default.removeItem(at: recording) }

        let organizer = makeOrganizer(
            store: store,
            transport: VoiceTransportSpy().failing(with: URLError(.notConnectedToInternet))
        )

        await #expect(throws: OrganizeFailure.networkUnavailable) {
            try await organizer.organize(audioAt: recording, durationSeconds: 42, locale: Locale(identifier: "en_US"))
        }
    }

    @Test("cancellation passes through untouched, however it arrives")
    func rethrowsCancellation() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recording = try makeRecording(audioBytes)
        defer { try? FileManager.default.removeItem(at: recording) }

        let cancelled = makeOrganizer(store: store, transport: VoiceTransportSpy().failing(with: CancellationError()))
        await #expect(throws: CancellationError.self) {
            try await cancelled.organize(audioAt: recording, durationSeconds: 42, locale: Locale(identifier: "en_US"))
        }

        let cancelledTask = makeOrganizer(store: store, transport: VoiceTransportSpy().failing(with: URLError(.cancelled)))
        await #expect(throws: CancellationError.self) {
            try await cancelledTask.organize(audioAt: recording, durationSeconds: 42, locale: Locale(identifier: "en_US"))
        }
    }

    // MARK: - Reading a body back

    /// Latin-1 is the one encoding every byte survives, so a multipart body
    /// holding a recording can still be read as a `String`.
    private func text(_ data: Data) throws -> String {
        try #require(String(data: data, encoding: .isoLatin1))
    }

    /// The value of a text part, or `nil` if the body has no such part.
    private func field(_ name: String, in body: String) -> String? {
        let header = "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        guard let headerRange = body.range(of: header) else { return nil }
        guard let terminator = body.range(of: "\r\n--", range: headerRange.upperBound..<body.endIndex) else {
            return nil
        }
        return String(body[headerRange.upperBound..<terminator.lowerBound])
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
