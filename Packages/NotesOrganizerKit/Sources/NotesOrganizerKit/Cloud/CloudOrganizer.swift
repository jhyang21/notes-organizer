import Foundation

/// A premium tidy: the whole transcript in one call to the `tidynote_organize`
/// endpoint, which does the model work and answers with the same
/// `OrganizedNote` the on-device path produces. No chunking — the cloud
/// context holds far more than a transcript, and chunking is what forces the
/// merge-and-retitle dance on-device.
///
/// The network is injected as a closure, so the tests below it never open a
/// socket: they hand back canned bytes and assert on the request that would
/// have been sent.
public struct CloudOrganizer: NoteOrganizing {
    /// Long enough for a long transcript and a slow model, short enough that a
    /// wedged call doesn't sit on a user's screen forever.
    static let timeout: TimeInterval = 90

    /// TidyNote's function on a project it shares with another app, so the
    /// name carries the app, not just the verb.
    static let functionName = "tidynote_organize"

    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let config: CloudConfig
    private let store: EntitlementStore
    private let clientVersion: String
    private let transport: Transport

    public init(
        config: CloudConfig = .production,
        store: EntitlementStore = .shared,
        clientVersion: String = CloudOrganizer.bundleVersion(),
        transport: @escaping Transport = CloudOrganizer.urlSessionTransport()
    ) {
        self.config = config
        self.store = store
        self.clientVersion = clientVersion
        self.transport = transport
    }

    public func organize(_ text: String) async throws -> OrganizedNote {
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MeaningfulText.isWorthOrganizing(transcript) else {
            throw OrganizeFailure.emptyTranscript
        }

        let (data, response) = try await send(transcript)
        guard let http = response as? HTTPURLResponse else {
            throw OrganizeFailure.cloudUnavailable(reason: Copy.unreadable)
        }

        switch http.statusCode {
        case 200:
            return try decodeNote(from: data)
        case 429:
            throw quotaOrRateLimitFailure(from: data)
        default:
            throw OrganizeFailure.cloudUnavailable(reason: Copy.serverProblem)
        }
    }

    // MARK: - Request

    private func send(_ transcript: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: config.functionsURL.appending(path: Self.functionName))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")

        let body = RequestBody(
            text: transcript,
            appUserId: store.appUserID(),
            clientVersion: clientVersion
        )
        guard let encoded = try? JSONEncoder().encode(body) else {
            throw OrganizeFailure.cloudUnavailable(reason: Copy.unreadable)
        }
        request.httpBody = encoded

        do {
            return try await transport(request)
        } catch is CancellationError {
            // The caller walked away. `OrganizeRun` turns this into "nothing
            // to show and nothing to say", which is right — rethrow it whole.
            throw CancellationError()
        } catch let error as URLError {
            // A cancelled task reaches us as a `URLError`, not a
            // `CancellationError`; anything else at this layer is the network.
            if error.code == .cancelled { throw CancellationError() }
            throw OrganizeFailure.networkUnavailable
        } catch {
            throw OrganizeFailure.cloudUnavailable(reason: Copy.serverProblem)
        }
    }

    // MARK: - Response

    private func decodeNote(from data: Data) throws -> OrganizedNote {
        guard let success = try? JSONDecoder().decode(SuccessBody.self, from: data) else {
            throw OrganizeFailure.cloudUnavailable(reason: Copy.unreadable)
        }
        store.recordQuota(
            used: success.quota.used,
            limit: success.quota.limit,
            month: success.quota.month,
            isPro: success.plan == "pro"
        )
        // Sanitized on the way in for the same reason the on-device path
        // sanitizes: a renderer should never be handed a blank bullet.
        return OutputSanitizer.sanitize(success.note)
    }

    /// A 429 is either "you're out for the month" — a wall with an upsell —
    /// or "too fast", which is a wait. They read nothing alike to the user, so
    /// the code decides, not the status.
    private func quotaOrRateLimitFailure(from data: Data) -> OrganizeFailure {
        guard let envelope = try? JSONDecoder().decode(ErrorBody.self, from: data) else {
            return .cloudUnavailable(reason: Copy.serverProblem)
        }
        guard envelope.error.code == "quota_exhausted" else {
            return .cloudUnavailable(reason: Copy.busy)
        }
        if let quota = envelope.quota {
            store.recordQuota(used: quota.used, limit: quota.limit, month: quota.month, isPro: false)
        }
        return .cloudQuotaExhausted
    }

    // MARK: - Wire types

    private struct RequestBody: Encodable {
        let text: String
        let appUserId: String
        let clientVersion: String
    }

    private struct SuccessBody: Decodable {
        let note: OrganizedNote
        let quota: Quota
        let plan: String
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable {
            let code: String
        }

        let error: Detail
        let quota: Quota?
    }

    private struct Quota: Decodable {
        let used: Int
        let limit: Int
        let month: String
    }

    // MARK: - Copy

    /// Failure text goes straight to the user under "The tidy service hit a
    /// snag", so it says what to do and names no vendor, endpoint, or status.
    private enum Copy {
        static let busy = "The service is busy right now. Try again in a moment."
        static let serverProblem = "Something went wrong on our end. Try again in a moment."
        static let unreadable = "We couldn't read the tidied note that came back. Try again."
    }

    // MARK: - Defaults

    /// The real network: one ephemeral session, no waiting around for
    /// connectivity — an offline user should see "You're offline" now, not in
    /// ninety seconds.
    public static func urlSessionTransport() -> Transport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: configuration)
        return { request in try await session.data(for: request) }
    }

    /// Sent so a server-side log can tell which build produced a request;
    /// never used for anything the user sees.
    public static func bundleVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
