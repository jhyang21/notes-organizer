import Foundation

/// A tidy: the whole transcript in one call to the `tidynote_organize`
/// endpoint, which does the model work and answers with an `OrganizedNote`.
/// No chunking — the context there holds far more than anyone talks in one
/// sitting.
///
/// The network is injected as a closure, so the tests below it never open a
/// socket: they hand back canned bytes and assert on the request that would
/// have been sent.
public struct CloudOrganizer: NoteOrganizing, VoiceOrganizing {
    /// Long enough for a long transcript and a slow model, short enough that a
    /// wedged call doesn't sit on a user's screen forever.
    static let timeout: TimeInterval = 90

    /// The voice path uploads a recording and waits for it to be transcribed
    /// before the model even starts, so it gets more room than the text path.
    static let audioTimeout: TimeInterval = 150

    /// The session's own ceiling. `URLSession` takes whichever is *smaller*,
    /// this or the request's own `timeoutInterval`, so a session set to the
    /// text path's ninety seconds would quietly cut the audio path's hundred
    /// and fifty down to it — a long recording would fail on a clock the
    /// request never asked for. Setting it to the longest any request may take
    /// leaves each request's own value the one that decides.
    static let sessionTimeout: TimeInterval = max(timeout, audioTimeout)

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
        return try note(from: data, response: response)
    }

    /// The same tidy from a recording instead of typed text: the server
    /// transcribes it and organizes the transcript in one round trip, so the
    /// device never runs speech recognition at all.
    ///
    /// The file is read into memory rather than streamed. A capture is about a
    /// megabyte, and reading it keeps `Transport` a plain
    /// request-in/bytes-out closure — which is what lets every test below run
    /// without a socket.
    public func organize(audioAt url: URL, durationSeconds: Double, locale: Locale) async throws -> OrganizedNote {
        guard let audio = try? Data(contentsOf: url) else {
            throw OrganizeFailure.cloudUnavailable(reason: Copy.unreadableRecording)
        }

        let (data, response) = try await sendAudio(audio, durationSeconds: durationSeconds, locale: locale)
        return try note(from: data, response: response)
    }

    // MARK: - Request

    private func send(_ transcript: String) async throws -> (Data, URLResponse) {
        var request = makeRequest(timeout: Self.timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = RequestBody(
            text: transcript,
            appUserId: store.appUserID(),
            clientVersion: clientVersion
        )
        guard let encoded = try? JSONEncoder().encode(body) else {
            throw OrganizeFailure.cloudUnavailable(reason: Copy.unreadable)
        }
        request.httpBody = encoded

        return try await perform(request)
    }

    private func sendAudio(_ audio: Data, durationSeconds: Double, locale: Locale) async throws -> (Data, URLResponse) {
        var body = MultipartFormBody()
        body.appendFile(name: "audio", filename: "capture.m4a", contentType: "audio/mp4", data: audio)
        body.appendField(name: "appUserId", value: store.appUserID())
        body.appendField(name: "clientVersion", value: clientVersion)
        body.appendField(name: "durationSeconds", value: Self.wholeSeconds(durationSeconds))
        // BCP-47 because that is what a transcription service reads. Left out
        // entirely when there is nothing to say, so the server picks rather
        // than being handed an empty string to interpret.
        let languageTag = locale.identifier(.bcp47)
        if !languageTag.isEmpty {
            body.appendField(name: "locale", value: languageTag)
        }

        var request = makeRequest(timeout: Self.audioTimeout)
        request.setValue(body.contentTypeHeader, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.encoded()

        return try await perform(request)
    }

    /// Everything the two paths agree on: where the call goes, how it
    /// authenticates, and how long it may take. Only the body and its
    /// `Content-Type` differ.
    private func makeRequest(timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: config.functionsURL.appending(path: Self.functionName))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        return request
    }

    /// The duration is a hint for the server's own limits, not a measurement
    /// anyone reports, so whole seconds are plenty — and a nonsense value
    /// (a capture that never started, an infinity out of a broken asset)
    /// becomes zero rather than something unprintable.
    ///
    /// Capped as well as floored, because `Int(_:)` traps on a `Double` too
    /// large to hold and "finite" is not the same as "small". A day is longer
    /// than any capture, and the server rejects on its own limit long before
    /// that.
    private static func wholeSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0" }
        return String(Int(min(seconds.rounded(), 86_400)))
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
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

    /// The one place a reply becomes either a note or a failure. Both paths
    /// call the same function and get the same envelope back, so both read it
    /// the same way.
    private func note(from data: Data, response: URLResponse) throws -> OrganizedNote {
        guard let http = response as? HTTPURLResponse else {
            throw OrganizeFailure.cloudUnavailable(reason: Copy.unreadable)
        }

        switch http.statusCode {
        case 200:
            return try decodeNote(from: data)
        case 429:
            throw quotaOrRateLimitFailure(from: data)
        case 413:
            // A recording the endpoint won't take. The user can do something
            // about that, so it gets its own screen rather than "try again".
            throw OrganizeFailure.audioTooLarge
        case 422:
            // Nothing audible in the recording — the same dead end as text
            // with nothing in it, and it reads the same way.
            throw OrganizeFailure.emptyTranscript
        default:
            throw OrganizeFailure.cloudUnavailable(reason: Copy.serverProblem)
        }
    }

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
        // Sanitized on the way in: a renderer should never be handed a blank
        // bullet, whatever the model did.
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
        // A voice reply also carries `transcript`. `JSONDecoder` ignores keys
        // it wasn't asked about, so leaving it out costs nothing — and there
        // is nowhere in the app to put a transcript yet.
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
        static let busy = String(localized: "The service is busy right now. Try again in a moment.", bundle: .module)
        static let serverProblem = String(localized: "Something went wrong on our end. Try again in a moment.", bundle: .module)
        static let unreadable = String(localized: "We couldn't read the tidied note that came back. Try again.", bundle: .module)
        static let unreadableRecording = String(localized: "We couldn't read that recording. Try recording it again.", bundle: .module)
    }

    // MARK: - Defaults

    /// The real network: one ephemeral session, no waiting around for
    /// connectivity — an offline user should see "You're offline" now, not in
    /// ninety seconds.
    public static func urlSessionTransport() -> Transport {
        let session = URLSession(configuration: sessionConfiguration())
        return { request in try await session.data(for: request) }
    }

    /// Split out from the transport so the timeout the session imposes on
    /// every request can be asserted on. `timeoutIntervalForResource` is left
    /// at its default: it measures the whole transfer rather than a stall, and
    /// capping that would punish a slow upload of a perfectly good recording.
    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = sessionTimeout
        return configuration
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
