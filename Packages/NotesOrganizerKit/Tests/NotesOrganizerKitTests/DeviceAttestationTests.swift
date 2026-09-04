import Foundation
import Testing
@testable import NotesOrganizerKit

/// Same job as the spies in the other two cloud suites: hold the request the
/// organizer would have sent, answer with whatever the test decided, and open
/// no socket doing it.
private final class AttestTransportSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

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

    private func record(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }
}

/// Stands in for `DeviceAttestor`, which needs a Secure Enclave and so cannot
/// run here at all. It hands back fixed headers and keeps the bytes it was
/// asked to sign, which is what lets a test check that those bytes are the
/// ones that went out.
private actor AttestorStub: DeviceAttesting {
    private let headers: [String: String]
    private(set) var signedBodies: [Data] = []
    private(set) var signedAppUserIDs: [String] = []
    private(set) var invalidations = 0

    init(headers: [String: String] = [
        "X-TidyNote-Key-Id": "test-key-id",
        "X-TidyNote-Assertion": "dGVzdC1hc3NlcnRpb24=",
    ]) {
        self.headers = headers
    }

    func assertionHeaders(for body: Data, appUserID: String) async -> [String: String] {
        signedBodies.append(body)
        signedAppUserIDs.append(appUserID)
        return headers
    }

    func invalidate() async {
        invalidations += 1
    }
}

@Suite("Device attestation")
struct DeviceAttestationTests {
    private let config = CloudConfig(
        functionsURL: URL(string: "https://example-project.supabase.co/functions/v1")!,
        anonKey: "test-publishable-key"
    )

    private let transcript = "Talked to Priya about the kitchen quotes and the timeline for August."

    private let audioBytes = Data([0x00, 0x20, 0xFF, 0x0D, 0x0A, 0x2D, 0x2D, 0x80, 0x7F])

    private let successJSON = """
    {
      "note": { "title": "Kitchen quotes", "summary": "", "sections": [] },
      "quota": { "used": 2, "limit": 5, "remaining": 3, "month": "2026-08" },
      "plan": "free"
    }
    """

    // MARK: - Fixtures

    private func makeStore() throws -> (EntitlementStore, String, UserDefaults) {
        let suiteName = "DeviceAttestationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (EntitlementStore(defaults: defaults), suiteName, defaults)
    }

    private func makeOrganizer(
        store: EntitlementStore,
        transport: @escaping CloudOrganizer.Transport,
        attestor: any DeviceAttesting
    ) -> CloudOrganizer {
        CloudOrganizer(config: config, store: store, clientVersion: "1.2 (34)", transport: transport, attestor: attestor)
    }

    private func makeRecording(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tidynote-attest-test-\(UUID().uuidString).m4a")
        try bytes.write(to: url)
        return url
    }

    // MARK: - Headers

    @Test("a tidy carries both attestation headers, over the body that was signed")
    func textPathSendsSignedBody() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let spy = AttestTransportSpy()
        let attestor = AttestorStub()
        let organizer = makeOrganizer(
            store: store,
            transport: spy.responding(status: 200, json: successJSON),
            attestor: attestor
        )

        _ = try await organizer.organize(transcript)

        let request = try #require(spy.lastRequest)
        #expect(request.value(forHTTPHeaderField: "X-TidyNote-Key-Id") == "test-key-id")
        #expect(request.value(forHTTPHeaderField: "X-TidyNote-Assertion") == "dGVzdC1hc3NlcnRpb24=")

        // The signature covers the exact bytes. A body encoded twice, or
        // encoded after signing, would fail on the server and be very hard to
        // see from here.
        let signed = await attestor.signedBodies
        #expect(signed.count == 1)
        #expect(request.httpBody == signed.first)

        // The key is registered against one app user id, and the server checks
        // the pair. Signing under a different id than the body carries would be
        // rejected every time.
        let ids = await attestor.signedAppUserIDs
        #expect(ids == [store.appUserID()])
    }

    @Test("a recording is attested the same way, over the multipart bytes")
    func voicePathSendsSignedBody() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recording = try makeRecording(audioBytes)
        defer { try? FileManager.default.removeItem(at: recording) }

        let spy = AttestTransportSpy()
        let attestor = AttestorStub()
        let organizer = makeOrganizer(
            store: store,
            transport: spy.responding(status: 200, json: successJSON),
            attestor: attestor
        )

        _ = try await organizer.organize(audioAt: recording, durationSeconds: 12, locale: Locale(identifier: "en_US"))

        let request = try #require(spy.lastRequest)
        #expect(request.value(forHTTPHeaderField: "X-TidyNote-Key-Id") == "test-key-id")
        #expect(request.value(forHTTPHeaderField: "X-TidyNote-Assertion") == "dGVzdC1hc3NlcnRpb24=")

        let signed = await attestor.signedBodies
        #expect(signed.count == 1)
        #expect(request.httpBody == signed.first)
    }

    @Test("an attestor with nothing to offer leaves the headers off entirely")
    func unattestedCallsCarryNoHeaders() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let spy = AttestTransportSpy()
        let organizer = makeOrganizer(
            store: store,
            transport: spy.responding(status: 200, json: successJSON),
            attestor: NoopAttestor()
        )

        _ = try await organizer.organize(transcript)

        let request = try #require(spy.lastRequest)
        // Half a pair is worse than none: the server reads one header alone as
        // a forgery attempt and refuses the call.
        #expect(request.value(forHTTPHeaderField: "X-TidyNote-Key-Id") == nil)
        #expect(request.value(forHTTPHeaderField: "X-TidyNote-Assertion") == nil)
    }

    // MARK: - Responses

    @Test("a 426 is a build the service will no longer tidy for")
    func mapsUpdateRequired() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let organizer = makeOrganizer(
            store: store,
            transport: AttestTransportSpy().responding(status: 426, json: #"{"error":{"code":"update_required"}}"#),
            attestor: AttestorStub()
        )

        await #expect(throws: OrganizeFailure.updateRequired) {
            try await organizer.organize(transcript)
        }
    }

    @Test("a rejected key is thrown away so the next call registers a new one")
    func invalidatesOnAttestationInvalid() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let attestor = AttestorStub()
        let organizer = makeOrganizer(
            store: store,
            transport: AttestTransportSpy().responding(status: 401, json: #"{"error":{"code":"attestation_invalid"}}"#),
            attestor: attestor
        )

        let failure = await capture { _ = try await organizer.organize(transcript) }
        guard case .cloudUnavailable = try #require(failure) else {
            Issue.record("expected cloudUnavailable, got \(String(describing: failure))")
            return
        }

        let invalidations = await attestor.invalidations
        #expect(invalidations == 1)
    }

    @Test("a 401 that isn't about the key leaves the key alone")
    func keepsKeyOnOther401() async throws {
        let (store, suiteName, defaults) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let attestor = AttestorStub()
        let organizer = makeOrganizer(
            store: store,
            transport: AttestTransportSpy().responding(status: 401, json: #"{"error":{"code":"unauthorized"}}"#),
            attestor: attestor
        )

        _ = await capture { _ = try await organizer.organize(transcript) }

        // Dropping a good key over an unrelated 401 would cost a fresh
        // attestation, and the rate limit only allows five an hour.
        let invalidations = await attestor.invalidations
        #expect(invalidations == 0)
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
