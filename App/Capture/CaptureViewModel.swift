import AVFoundation
import Foundation
import NotesOrganizerKit
import Observation

/// Reasons a capture can't produce a note that are the app's own —
/// permissions, speech-asset download, the audio pipeline. Everything from the
/// organizer onwards is an `OrganizeFailure`, which the package's
/// `UnavailableView` already has copy and an action for.
enum CaptureFailure: Equatable {
    case microphonePermissionDenied
    case assetsUnsupported
    case assetDownloadFailed(String)
    case captureFailed(String)
    case emptyRecording
}

/// Drives the capture flow end to end: idle → requestingPermissions →
/// downloadingAssets → recording → organizing → preview, or failed at any
/// step. Owns `AudioCaptureService`, `TranscriptionService`, and
/// `SpeechAssetManager`; `OrganizeRouting` supplies the organizer, so tests
/// and previews swap in a `MockOrganizer` by handing over a routing built
/// around one.
@MainActor
@Observable
final class CaptureViewModel {
    enum State: Equatable {
        case idle
        case requestingPermissions
        case downloadingAssets(progress: Double)
        case recording(liveTranscript: String, level: Float, elapsed: Duration)
        case organizing
        case preview(OrganizedNote)
        case failed(CaptureFailure)
        case unavailable(OrganizeFailure)
    }

    private(set) var state: State = .idle

    /// The first-run screen, which every install sees once before it can
    /// record anything. Settable so SwiftUI can bind to it.
    var isShowingFirstRun = false

    private let routing: OrganizeRouting
    private let log: DiagnosticsLog
    private let locale: Locale
    private let audioCapture: AudioCaptureService
    private let transcription: TranscriptionService
    private let assetManager: SpeechAssetManager
    private let clock = ContinuousClock()

    private var silenceDetector = SilenceDetector()
    private var lifecycleTask: Task<Void, Never>?
    private var organizeTask: Task<Void, Never>?
    private var recordingTasks: [Task<Void, Never>] = []
    private var isFinishingRecording = false

    /// Kept so every retry re-organizes what the user actually said instead of
    /// throwing the recording away and asking them to say it again.
    private var lastTranscript: String?
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
        self.audioCapture = AudioCaptureService()
        self.transcription = TranscriptionService(locale: locale)
        self.assetManager = SpeechAssetManager()

        audioCapture.onInterrupted = { [weak self] in
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

    /// "Try again" on a failure screen. Re-organizes the transcript we still
    /// have rather than discarding a recording the user just made — the only
    /// things there is no point re-running are a transcript with nothing in it
    /// and a recording too long to send. Both need a new recording.
    func retry() {
        switch state {
        case .unavailable(.emptyTranscript), .unavailable(.audioTooLarge):
            reset()
        default:
            guard lastTranscript != nil else {
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

    /// Abandons an in-progress or completed capture and returns to idle.
    func reset() {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        organizeTask?.cancel()
        organizeTask = nil
        recordingTasks.forEach { $0.cancel() }
        recordingTasks = []
        isFinishingRecording = false
        transcription.cancel()
        audioCapture.stop()
        silenceDetector = SilenceDetector()
        lastTranscript = nil
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
        // from last time — the transcript is still here and the user has
        // answered, so finish what they asked for.
        if lastTranscript != nil {
            startOrganize()
        }
    }

    // MARK: - Lifecycle

    private func runCaptureLifecycle() async {
        state = .requestingPermissions
        guard await audioCapture.requestPermission() else {
            state = .failed(.microphonePermissionDenied)
            return
        }
        guard !Task.isCancelled else { return }

        do {
            try await assetManager.ensureAssets(for: locale, transcriber: transcription.transcriber) { [weak self] status in
                guard let self else { return }
                switch status {
                case .needsDownload:
                    self.state = .downloadingAssets(progress: 0)
                case .downloading(let progress):
                    self.state = .downloadingAssets(progress: progress)
                case .checking, .ready, .unsupported, .failed:
                    break
                }
            }
        } catch SpeechAssetError.unsupported {
            state = .failed(.assetsUnsupported)
            return
        } catch SpeechAssetError.installFailed(let message) {
            state = .failed(.assetDownloadFailed(message))
            return
        } catch {
            state = .failed(.assetDownloadFailed(error.localizedDescription))
            return
        }
        guard !Task.isCancelled else { return }

        beginRecording()
    }

    private func beginRecording() {
        silenceDetector = SilenceDetector()
        isFinishingRecording = false
        let startedAt = clock.now

        let buffers: AsyncStream<AVAudioPCMBuffer>
        let levels: AsyncStream<Float>
        let transcriptUpdates: AsyncStream<TranscriptUpdate>
        do {
            (buffers, levels) = try audioCapture.start()
            transcriptUpdates = try transcription.start()
        } catch {
            state = .failed(.captureFailed(error.localizedDescription))
            return
        }

        state = .recording(liveTranscript: "", level: 0, elapsed: .zero)

        // Three independent consumers, all MainActor-isolated (they're
        // spawned from this MainActor method, so `Task { }` inherits that
        // isolation): buffers just feed the transcriber, levels drive
        // elapsed/level UI state and the silence check, and transcript
        // updates drive the live-text state and double as an activity
        // signal per the plan (a volatile update can arrive without the
        // meter crossing threshold, e.g. quiet speech).
        let bufferTask = Task { [weak self] in
            for await buffer in buffers {
                self?.transcription.append(buffer)
            }
        }

        let levelTask = Task { [weak self] in
            guard let self else { return }
            for await level in levels {
                guard case .recording(let liveTranscript, _, _) = self.state else { continue }
                let elapsed = self.clock.now - startedAt
                self.state = .recording(liveTranscript: liveTranscript, level: level, elapsed: elapsed)

                switch self.silenceDetector.evaluate(elapsed: elapsed, level: level) {
                case .continue:
                    break
                case .autoStopSilence, .hardCapReached:
                    self.finishRecording()
                }
            }
        }

        let transcriptTask = Task { [weak self] in
            guard let self else { return }
            for await update in transcriptUpdates {
                guard case .recording(_, let level, let elapsed) = self.state else { continue }
                self.state = .recording(liveTranscript: update.displayText, level: level, elapsed: elapsed)

                let hasSpeech = !update.volatileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                guard hasSpeech else { continue }
                let elapsedNow = self.clock.now - startedAt
                if self.silenceDetector.evaluate(elapsed: elapsedNow, isActive: true) == .hardCapReached {
                    self.finishRecording()
                }
            }
        }

        recordingTasks = [bufferTask, levelTask, transcriptTask]
    }

    /// Stops capture (from a manual tap, auto-stop, an interruption, or the
    /// hard cap) and moves on to organizing. Idempotent — safe to call from
    /// more than one signal racing to end the same recording.
    private func finishRecording() {
        guard case .recording = state, !isFinishingRecording else { return }
        isFinishingRecording = true

        recordingTasks.forEach { $0.cancel() }
        recordingTasks = []
        audioCapture.stop()

        lifecycleTask?.cancel()
        lifecycleTask = Task { [weak self] in
            await self?.organizeCapturedTranscript()
        }
    }

    private func organizeCapturedTranscript() async {
        let finalTranscript = await transcription.finish()
        isFinishingRecording = false

        let trimmed = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .failed(.emptyRecording)
            return
        }

        lastTranscript = trimmed
        startOrganize()
    }

    // MARK: - Organizing

    /// Decides the route before anything runs, because two of its outcomes are
    /// screens rather than a tidy: the first-run screen, and the quota wall.
    private func startOrganize() {
        guard let transcript = lastTranscript else { return }

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
        organizeTask = Task { [weak self] in
            await self?.run(transcript)
        }
    }

    private func route() -> RoutingPolicy.Route {
        routing.route(consentGrantedThisSession: hasGrantedConsentThisSession)
    }

    private func run(_ transcript: String) async {
        // `reset()` between scheduling this task and its first line would
        // otherwise leave a spinner on a screen that's back at idle.
        guard !Task.isCancelled else { return }

        state = .organizing

        switch await OrganizeRun(organizer: routing.organizer(), source: .app, log: log).run(transcript) {
        case .success(let outcome):
            state = .preview(outcome.note)
        case .failure(let failure):
            state = .unavailable(failure)
        case nil:
            // Cancelled — `reset()` has already put the machine back to idle.
            break
        }
    }
}
