import AVFoundation
import Foundation
import NotesOrganizerKit
import Observation

/// Reasons a capture can't produce a note that are the app's own —
/// permissions, model-asset download, the audio pipeline. Everything from the
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
/// and previews swap in `MockOrganizer` by handing over a routing that only
/// knows about on-device.
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
        /// A premium tidy that didn't work out, holding on to the note the
        /// user already had. Losing a good tidy because the optional better
        /// one failed would be a bad trade.
        case premiumTidyFailed(note: OrganizedNote, failure: OrganizeFailure)
    }

    private(set) var state: State = .idle

    /// What the preview offers after an on-device tidy, or `nil` when there is
    /// nothing to offer — Pro, a spent quota, the cloud switched off.
    private(set) var premiumTidyOffer: PremiumTidyOffer?

    /// The one-time cloud consent sheet. Settable so SwiftUI can bind to it;
    /// a swipe-dismissal lands in `cloudConsentDismissed()`.
    var isShowingCloudConsent = false

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
    /// The note a premium tidy would replace, so a failed one can hand it back.
    private var previewedNote: OrganizedNote?
    private var pendingPreference: RoutingPolicy.Preference?
    /// Set once the user says yes, so a device that can't remember the answer
    /// asks once rather than forever.
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

    /// Checks Apple Intelligence before anything is recorded, so an
    /// ineligible iPhone says so on launch rather than after the user has
    /// talked for two minutes. Only ever moves the machine out of `.idle`.
    func checkModelAvailability() {
        guard case .idle = state else { return }
        guard let failure = ModelAvailability.currentFailure() else { return }
        state = .unavailable(failure)
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
    /// thing there is no point re-running is a transcript with nothing in it.
    func retry() {
        if case .unavailable(.emptyTranscript) = state {
            reset()
            return
        }
        guard lastTranscript != nil else {
            reset()
            return
        }
        startOrganize(preference: .automatic)
    }

    /// The premium tidy button, on the preview and on the on-device-failure
    /// screen. Same transcript, forced through the cloud.
    func requestPremiumTidy() {
        startOrganize(preference: .forceCloud)
    }

    /// Puts the note that was on screen before a failed premium tidy back.
    func returnToPreview() {
        guard case .premiumTidyFailed(let note, _) = state else { return }
        showPreview(note)
    }

    /// Re-reads the plan after the paywall closes. A subscription bought at a
    /// wall was bought to get past it, so the tidy that hit the wall runs
    /// again rather than making the user find the button a second time.
    func refreshPlan() {
        switch state {
        case .preview:
            premiumTidyOffer = routing.premiumTidyOffer()
        case .unavailable, .premiumTidyFailed:
            guard routing.isPro else { return }
            requestPremiumTidy()
        default:
            break
        }
    }

    /// Abandons an in-progress or completed capture and returns to idle.
    /// Re-runs the availability check on the way, so "Try again" on a
    /// model-not-ready screen lands back on that screen while the model is
    /// still unavailable, instead of on a record button that can't work.
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
        previewedNote = nil
        premiumTidyOffer = nil
        pendingPreference = nil
        state = .idle
        checkModelAvailability()
    }

    // MARK: - Consent

    func acceptCloudConsent() {
        routing.setCloudConsentGranted(true)
        hasGrantedConsentThisSession = true
        isShowingCloudConsent = false

        let preference = pendingPreference ?? .automatic
        pendingPreference = nil
        startOrganize(preference: preference)
    }

    func declineCloudConsent() {
        isShowingCloudConsent = false
        let preference = pendingPreference
        pendingPreference = nil

        // A declined premium tidy leaves the note already on screen alone. A
        // declined automatic run is on hardware that has no other way to
        // organize anything, so it gets the screen that explains that.
        if preference == .automatic {
            state = .unavailable(.cloudConsentNeeded)
        }
    }

    /// The sheet went away without an answer — swiped rather than tapped.
    /// Reads the same as "Not now": nothing is sent.
    func cloudConsentDismissed() {
        guard pendingPreference != nil else { return }
        declineCloudConsent()
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
        startOrganize(preference: .automatic)
    }

    // MARK: - Organizing

    /// Decides the route before anything runs, because two of its outcomes are
    /// screens rather than organizers. Consent is the one this method handles
    /// itself; the rest are failures `OrganizerRouter` throws, so they reach
    /// the user through the same path as any other failed organize — logged
    /// once, shown once.
    private func startOrganize(preference: RoutingPolicy.Preference) {
        guard let transcript = lastTranscript else { return }

        let route = routing.route(preference: preference, onDeviceFailure: ModelAvailability.currentFailure())
        if case .consentNeeded = route, !hasGrantedConsentThisSession {
            pendingPreference = preference
            isShowingCloudConsent = true
            return
        }

        organizeTask?.cancel()
        organizeTask = Task { [weak self] in
            await self?.run(transcript, route: route)
        }
    }

    private func run(_ transcript: String, route: RoutingPolicy.Route) async {
        // `reset()` between scheduling this task and its first line would
        // otherwise leave a spinner on a screen that's back at idle.
        guard !Task.isCancelled else { return }

        let noteToKeep = previewedNote
        state = .organizing

        let organizer = routing.organizer(for: route, source: .app, log: log)
        switch await OrganizeRun(organizer: organizer, source: .app, log: log).run(transcript) {
        case .success(let outcome):
            showPreview(outcome.note, cameFromOnDevice: route == .onDevice)
        case .failure(let failure):
            if let noteToKeep {
                state = .premiumTidyFailed(note: noteToKeep, failure: failure)
            } else {
                state = .unavailable(failure)
            }
        case nil:
            // Cancelled — `reset()` has already put the machine back to idle.
            break
        }
    }

    /// The premium tidy is only offered on top of a plain one. A note that
    /// already came from the cloud has nothing better to be re-run through,
    /// and offering it a count would read as though it hadn't been.
    private func showPreview(_ note: OrganizedNote, cameFromOnDevice: Bool = true) {
        previewedNote = note
        premiumTidyOffer = cameFromOnDevice ? routing.premiumTidyOffer() : nil
        state = .preview(note)
    }
}
