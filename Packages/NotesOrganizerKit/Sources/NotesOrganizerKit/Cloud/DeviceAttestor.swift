import CryptoKit
import Foundation
import Security

#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// Proof that a call came from a real install of TidyNote.
///
/// The organize endpoint has no accounts. A caller says which anonymous app
/// user it is and the server takes its word for it, which is enough to count
/// tidies and nothing at all against someone who lifts an id out of the app
/// and spends another install's month. App Attest closes that gap: the Secure
/// Enclave holds a key Apple vouched for, the key is bound to one app user id
/// when it is registered, and every organize call signs its own body with it.
/// A borrowed id without the key buys nothing.
///
/// Nothing here throws at the caller. A device that cannot attest, a key that
/// stopped working, a registration that never landed: each of them returns no
/// headers and lets the call go out unattested. What an unattested call is
/// worth is the server's decision. A client that refused to send one would
/// take the whole app down every time verification had a bad day.
public protocol DeviceAttesting: Sendable {
    /// The headers to add to one organize call.
    ///
    /// - Parameter body: the exact bytes that will be sent. The signature
    ///   covers them, so a caller that re-encodes the body afterwards has
    ///   invalidated the header it was just handed.
    func assertionHeaders(for body: Data, appUserID: String) async -> [String: String]

    /// Throws the stored key away, for when the server says it does not know
    /// it. The next call generates and registers another.
    func invalidate() async
}

/// No attestation at all: for tests, for previews, and for any caller with no
/// business talking to the Secure Enclave.
public struct NoopAttestor: DeviceAttesting {
    public init() {}

    public func assertionHeaders(for body: Data, appUserID: String) async -> [String: String] { [:] }

    public func invalidate() async {}
}

/// The real one.
///
/// An actor because the first call runs the whole generate-attest-register
/// sequence, and two tidies started at once would otherwise mint two keys and
/// register the second over the first.
public actor DeviceAttestor: DeviceAttesting {
    /// Long enough for Apple's servers and then ours, short enough that a
    /// wedged registration does not sit in front of the tidy waiting on it.
    static let registrationTimeout: TimeInterval = 20

    /// One item per process. The service names the app; the account, set at
    /// init, names the target.
    static let keychainService = "com.immform.notesorganizer.appattest"

    static let keyIDHeader = "X-TidyNote-Key-Id"
    static let assertionHeader = "X-TidyNote-Assertion"

    /// Printed in DEBUG only, so a real attestation can be captured off a
    /// device and checked in as a server-side test fixture. Nothing off a
    /// simulator can produce one. See
    /// `supabase/functions/tidynote_organize/fixtures/README.md`.
    static let fixturePrefix = "TIDYNOTE_ATTEST_FIXTURE"

    private let config: CloudConfig
    private let transport: CloudOrganizer.Transport
    private let keychainAccount: String

    /// - Parameter keychainAccount: the app and the share extension are
    ///   separate processes with separate keychains, so each ends up holding a
    ///   key of its own and registering it under its own id. Keyed by bundle
    ///   id so that stays true if a third target ever calls the endpoint.
    public init(
        config: CloudConfig = .production,
        transport: @escaping CloudOrganizer.Transport = CloudOrganizer.urlSessionTransport(),
        keychainAccount: String = Bundle.main.bundleIdentifier ?? "tidynote"
    ) {
        self.config = config
        self.transport = transport
        self.keychainAccount = keychainAccount
    }

    public func invalidate() async {
        deleteState()
    }

    #if canImport(DeviceCheck)

    public func assertionHeaders(for body: Data, appUserID: String) async -> [String: String] {
        // False on every simulator, and on any device Apple has not shipped
        // the feature to.
        guard isSupported else { return [:] }

        var state: AttestState
        if let stored = loadState() {
            state = stored
        } else {
            guard let keyID = try? await generateKey() else { return [:] }
            state = AttestState(keyID: keyID, registered: false)
            save(state)
        }

        if !state.registered {
            switch await register(state, appUserID: appUserID) {
            case .registered:
                state.registered = true
                save(state)
            case .rejected:
                deleteState()
                return [:]
            case .retryLater:
                return [:]
            }
        }

        // The server hashes the body it received and checks this signature
        // against it, so the bytes signed here are the bytes that must go out.
        let assertion: Data
        do {
            assertion = try await generateAssertion(state.keyID, clientDataHash: Data(SHA256.hash(data: body)))
        } catch {
            // `DCError.invalidKey` and everything else land in the same place:
            // the key being held can no longer sign, so drop it and let the
            // next call start a fresh one.
            deleteState()
            return [:]
        }

        return [
            Self.keyIDHeader: state.keyID,
            Self.assertionHeader: assertion.base64EncodedString(),
        ]
    }

    // MARK: - Registration

    /// What one registration attempt settled.
    private enum Registration {
        /// The server has the key and will accept assertions from it.
        case registered
        /// The key is no good to us. Drop it and generate another.
        case rejected
        /// Nothing was decided. Keep the key and try again on the next call.
        case retryLater
    }

    /// Hands the attestation to the function, which checks the chain against
    /// Apple's root and stores the public key against this app user id.
    private func register(_ state: AttestState, appUserID: String) async -> Registration {
        // The server checks this timestamp against its own clock and rejects
        // anything more than five minutes out, so it is read as late as
        // possible: right before the call that carries it.
        let timestamp = Int(Date().timeIntervalSince1970)
        let clientDataHash = Data(SHA256.hash(data: Data("\(appUserID)|\(timestamp)".utf8)))

        let attestation: Data
        do {
            attestation = try await attestKey(state.keyID, clientDataHash: clientDataHash)
        } catch {
            // Apple refused to attest this key. Keeping it would mean failing
            // the same way on every call from here on.
            return .rejected
        }

        #if DEBUG
        printFixture(keyID: state.keyID, attestation: attestation, appUserID: appUserID, timestamp: timestamp)
        #endif

        let payload = AttestBody(
            appUserId: appUserID,
            keyId: state.keyID,
            attestation: attestation.base64EncodedString(),
            timestamp: timestamp
        )
        guard let encoded = try? JSONEncoder().encode(payload) else { return .retryLater }

        var request = CloudOrganizer.makeRequest(config: config, timeout: Self.registrationTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = encoded

        // The body is a 204 with nothing in it, so only the status is read.
        guard let received = try? await transport(request),
              let http = received.1 as? HTTPURLResponse else {
            // No answer at all. The network, not the key.
            return .retryLater
        }

        switch http.statusCode {
        case 204:
            return .registered
        case 429:
            // Registration is rate limited. Dropping the key here would mint
            // another and attest that one too, which is the single thing the
            // limit exists to stop.
            return .retryLater
        case 400..<500:
            return .rejected
        default:
            return .retryLater
        }
    }

    private struct AttestBody: Encodable {
        let op = "attest"
        let appUserId: String
        let keyId: String
        let attestation: String
        let timestamp: Int
    }

    // MARK: - Secure Enclave

    // Each call is wrapped so `DCAppAttestService` itself never crosses onto
    // the actor: only strings and bytes come back, which is all the flow above
    // needs and all that is safe to hand it.

    private nonisolated var isSupported: Bool {
        DCAppAttestService.shared.isSupported
    }

    private nonisolated func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    private nonisolated func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }

    private nonisolated func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
    }

    #if DEBUG
    /// One line, so it can be copied out of the Xcode console whole. Encoded
    /// rather than interpolated because the attestation is base64 and the app
    /// user id is not ours to assume anything about.
    private func printFixture(keyID: String, attestation: Data, appUserID: String, timestamp: Int) {
        let fixture = Fixture(
            keyId: keyID,
            attestation: attestation.base64EncodedString(),
            appUserId: appUserID,
            timestamp: timestamp
        )
        guard let encoded = try? JSONEncoder().encode(fixture),
              let json = String(data: encoded, encoding: .utf8) else { return }
        print("\(Self.fixturePrefix) \(json)")
    }

    private struct Fixture: Encodable {
        let keyId: String
        let attestation: String
        let appUserId: String
        let timestamp: Int
    }
    #endif

    #else

    /// Nowhere to keep a key and nothing to sign with, so the call goes bare.
    public func assertionHeaders(for body: Data, appUserID: String) async -> [String: String] { [:] }

    #endif

    // MARK: - Storage

    /// Small enough to live in one keychain item: which key is held, and
    /// whether the server has seen it. Registering twice is harmless, so the
    /// flag saves a round trip rather than recording anything load-bearing.
    private struct AttestState: Codable {
        var keyID: String
        var registered: Bool
    }

    /// `AfterFirstUnlockThisDeviceOnly`: a tidy can start from a share sheet
    /// before the user has looked at the screen, and a key that followed a
    /// backup to another device would be attesting hardware it was never
    /// generated on.
    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private func loadState() -> AttestState? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(AttestState.self, from: data)
    }

    private func save(_ state: AttestState) {
        guard let data = try? JSONEncoder().encode(state) else { return }

        let query = baseQuery()
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess { return }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        _ = SecItemAdd(insert as CFDictionary, nil)
    }

    private func deleteState() {
        _ = SecItemDelete(baseQuery() as CFDictionary)
    }
}
