import Foundation
import NotesOrganizerKit
import Observation

/// Reasons a capture can't produce a note that are the app's own — the
/// microphone, and the recording itself. Everything from the upload onwards is
/// an `OrganizeFailure`, which the package's `UnavailableView` already has
/// copy and an action for.
enum CaptureFailure: Equatable {
    case microphonePermissionDenied
    case captureFailed(String)
    case emptyRecording
}

/// Drives the capture flow end to end: idle → requestingPermissions →
/// recording → uploading → organizing → preview, or failed at any step. Owns
/// `AudioRecorderService`; `OrganizeRouting` supplies the organizer, so tests
/// and previews swap in a `MockOrganizer` by handing over a routing built
/// around one.
///
/// The recording is a file, and the file is kept until a note comes back.
/// That is what makes "Try again" mean try again rather than say it all
/// again: a tidy that failed offline, or on a server having a bad minute,
/// re-uploads the same recording.
@MainActor
@Observable
final class CaptureViewModel {
    enum State: Equatable {
        case idle
        case requestingPermissions
        case recording(level: Float, elapsed: Duration)
        case uploading
        case organizing
        case preview(OrganizedNote)
        case failed(CaptureFailure)
        case unavailable(OrganizeFailure)
    }

    /// A recording shorter than this is someone's stray tap, not something
    /// they said. Nothing is uploaded and nothing is kept.
    private static let minimumDuration: TimeInterval = 1

    /// How long "Sending your recording…" stays up. The client can't see the
    /// server change gear from receiving the audio to thinking about it, so
    /// the caption moves on a timer rather than pretending to know — long
    /// enough that a real upload is usually done, short enough that the screen
    /// never looks stuck.
    private static let uploadCaption = Duration.seconds(3)

    private(set) var state: State = .idle

    /// The first-run screen, which every install sees once before it can
    /// record anything. Settable so SwiftUI can bind to it.
    var isShowingFirstRun = false

    private let routing: OrganizeRouting
    private let log: DiagnosticsLog
    private let locale: Locale
    private let recorder: AudioRecorderService
    private let clock = ContinuousClock()

    private var silenceDetector = SilenceDetector()
    private var lifecycleTask: Task<Void, Never>?
    private var organizeTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?

    /// The recording waiting for a note. Kept so every retry sends what the
    /// user actually said instead of throwing it away and asking them to say
    /// it again; deleted the moment a note comes back, or the moment they walk
    /// away from it.
    private var recording: AudioRecorderService.Recording?
    /// Set once the user has read the first-run screen, so a device where the
    /// App Group write goes nowhere asks once rather than forever.
    private var hasGrantedConsentThisSession = false

    init(
        routing: OrganizeRouting = OrganizeRouting(),
        log: DiagnosticsLog = .shared,
        locale: Locale = .current
    ) {
        self.routing = routing
        self.log = log
        self.locale = locale
        self.recorder = AudioRecorderService()

        recorder.onInterrupted = { [weak self] in
            self?.finishRecording()
        }
    }

    // MARK: - Intents

    /// Puts the first-run screen up before anything else on an install that
    /// hasn't seen it. Told what TidyNote sends first, recorded second — the
    /// other order would be the app asking forgiveness.
    func showFirstRunIfNeeded() {
        if case .consentNeeded = route() {
            isShowingFirstRun = true
        }
    }

    func startCapture() {
        guard case .idle = state else { return }
        lifecycleTask?.cancel()
        lifecycleTask = Task { [weak self] in
            await self?.runCaptureLifecycle()
        }
    }

    /// User-initiated stop. Auto-stop (silence/hard cap) and interruption
    /// both route through the same `finishRecording()`.
    func stopRecording() {
        finishRecording()
    }

    /// "Try again" on a failure screen. Sends the recording we still have
    /// rather than discarding something the user just said — the only things
    /// there is no point re-sending are a recording with nothing audible in it
    /// and one too long for the service. Both need a new recording.
    func retry() {
        switch state {
        case .unavailable(.emptyTranscript), .unavailable(.audioTooLarge):
            reset()
        default:
            guard recording != nil else {
                reset()
                return
            }
            startOrganize()
        }
    }

    /// Re-reads the plan after the paywall closes. A subscription bought at the
    /// quota wall was bought to get past it, so the tidy that hit the wall runs
    /// again rather than making the user say it all over.
    func refreshPlan() {
        guard case .unavailable(.cloudQuotaExhausted) = state, routing.isPro else { return }
        startOrganize()
    }

    /// Abandons an in-progress or completed capture and returns to idle. The
    /// recording goes with it: the user has said they're done with it.
    func reset() {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        organizeTask?.cancel()
        organizeTask = nil
        levelTask?.cancel()
        levelTask = nil
        if let interrupted = recorder.stop() {
            delete(interrupted)
        }
        discardRecording()
        silenceDetector = SilenceDetector()
        state = .idle
    }

    // MARK: - Consent

    /// The only button on the first-run screen. Kept in the App Group so the
    /// share extension is covered by the same answer, and in this object too,
    /// for a device where that write goes nowhere.
    func acceptFirstRun() {
        routing.setCloudConsentGranted(true)
        hasGrantedConsentThisSession = true
        isShowingFirstRun = false

        // The screen goes up at launch, with nothing waiting behind it. If it
        // went up mid-flow instead — a device that couldn't keep the answer
        // from last time — the recording is still here and the user has
        // answered, so finish what they asked for.
        if recording != nil {
            startOrganize()
        }
    }

    // MARK: - Lifecycle

    private func runCaptureLifecycle() async {
        state = .requestingPermissions
        guard await recorder.requestPermission() else {
            state = .failed(.microphonePermissionDenied)
            return
        }
        guard !Task.isCancelled else { return }

        beginRecording()
    }

    private func beginRecording() {
        silenceDetector = SilenceDetector()
        let startedAt = clock.now

        let levels: AsyncStream<Float>
        do {
            levels = try recorder.start()
        } catch {
            state = .failed(.captureFailed(error.localizedDescription))
            return
        }

        state = .recording(level: 0, elapsed: .zero)

        // The meter is the only signal now that nothing is transcribed while
        // the user talks — which is what `SilenceDetector` was built around:
        // it drives the elapsed time and the level on screen, the pause that
        // stops a recording, and the five-minute cap.
        levelTask = Task { [weak self] in
            guard let self else { return }
            for await level in levels {
                guard case .recording = self.state else { continue }
                let elapsed = self.clock.now - startedAt
                self.state = .recording(level: level, elapsed: elapsed)

                switch self.silenceDetector.evaluate(elapsed: elapsed, level: level) {
                case .continue:
                    break
                case .autoStopSilence, .hardCapReached:
                    self.finishRecording()
                }
            }
        }
    }

    /// Stops recording (from a manual tap, auto-stop, an interruption, or the
    /// hard cap) and moves on to the upload. Idempotent — safe to call from
    /// more than one signal racing to end the same recording, because it runs
    /// start to finish without suspending and leaves the state somewhere other
    /// than `.recording` however it goes.
    private func finishRecording() {
        guard case .recording = state else { return }

        levelTask?.cancel()
        levelTask = nil

        guard let finished = recorder.stop() else {
            state = .failed(.captureFailed("The recording didn't save. Try again."))
            return
        }

        guard finished.duration >= Self.minimumDuration else {
            delete(finished)
            state = .failed(.emptyRecording)
            return
        }

        recording = finished
        startOrganize()
    }

    // MARK: - Organizing

    /// Decides the route before anything is sent, because two of its outcomes
    /// are screens rather than a tidy: the first-run screen, and the quota
    /// wall. Either way the recording stays where it is.
    private func startOrganize() {
        guard let recording else { return }

        switch route() {
        case .cloud:
            break
        case .consentNeeded:
            isShowingFirstRun = true
            return
        case .blocked(let failure):
            log.recordEvent(source: .app, message: "Organize blocked: \(failure)")
            state = .unavailable(failure)
            return
        }

        organizeTask?.cancel()
        // Set here rather than inside the task, so the state leaves
        // `.recording` in the same turn the recording stopped — nothing racing
        // to end it can find it still running.
        state = .uploading
        organizeTask = Task { [weak self] in
            await self?.run(recording)
        }
    }

    private func route() -> RoutingPolicy.Route {
        routing.route(consentGrantedThisSession: hasGrantedConsentThisSession)
    }

    private func run(_ recording: AudioRecorderService.Recording) async {
        // `reset()` between scheduling this task and its first line would
        // otherwise leave a spinner on a screen that's back at idle.
        guard !Task.isCancelled else { return }

        let caption = Task { [weak self] in
            try? await Task.sleep(for: Self.uploadCaption)
            guard let self, !Task.isCancelled, case .uploading = self.state else { return }
            self.state = .organizing
        }
        defer { caption.cancel() }

        let result = await OrganizeRun(source: .app, log: log).run(
            audioAt: recording.url,
            durationSeconds: recording.duration,
            locale: locale,
            with: routing.voiceOrganizer()
        )

        switch result {
        case .success(let outcome):
            // The note is here, so the recording has done its job.
            discardRecording()
            state = .preview(outcome.note)
        case .failure(let failure):
            state = .unavailable(failure)
        case nil:
            // Cancelled — `reset()` has already put the machine back to idle.
            break
        }
    }

    // MARK: - The file

    private func discardRecording() {
        if let recording {
            delete(recording)
        }
        recording = nil
    }

    private func delete(_ recording: AudioRecorderService.Recording) {
        try? FileManager.default.removeItem(at: recording.url)
    }
}
