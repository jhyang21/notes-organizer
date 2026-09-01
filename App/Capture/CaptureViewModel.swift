import Foundation
import NotesOrganizerKit
import Observation
import UIKit

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
/// recording → uploading → organizing → preview, or failed at any step. The
/// microphone arrives as an `AudioRecording` and the organizer as an
/// `OrganizeRouting`, so tests and previews swap in a scripted recorder and a
/// `MockOrganizer` rather than needing hardware.
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
        /// The recording is on disk and waiting for the user to say go —
        /// where a cancelled tidy lands. It carries the recording's length
        /// because that is all the screen needs to say what is being held.
        case readyToSend(duration: TimeInterval)
        case preview(OrganizedNote)
        case failed(CaptureFailure)
        case unavailable(OrganizeFailure)
    }

    /// Why the last recording ended. A silence auto-stop and a manual tap
    /// land on the same states, so the screen needs this to say something
    /// more useful than "it stopped" to VoiceOver.
    enum StopReason: Equatable {
        case manual
        case autoStopSilence
        case autoStopHardCap
        case interrupted
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
    /// Set the moment a recording ends, alongside the state transition that
    /// leaves `.recording` — read by the screen to word its VoiceOver
    /// announcement. `nil` until the first recording ends.
    private(set) var lastStopReason: StopReason?

    /// The first-run screen, which every install sees once before it can
    /// record anything. Settable so SwiftUI can bind to it.
    var isShowingFirstRun = false

    private let routing: OrganizeRouting
    private let log: DiagnosticsLog
    private let locale: Locale
    private let recorder: any AudioRecording
    private let silence: SilenceDetector.Configuration
    private let drafts: DraftStore
    private let isAppInForeground: @MainActor () -> Bool
    private let clock = ContinuousClock()

    private var silenceDetector: SilenceDetector
    private var lifecycleTask: Task<Void, Never>?
    private var organizeTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?

    /// The recording waiting for a note. Kept so every retry sends what the
    /// user actually said instead of throwing it away and asking them to say
    /// it again; deleted the moment a note comes back, or the moment they walk
    /// away from it.
    private var recording: CapturedRecording?
    /// Set once the user has read the first-run screen, so a device where the
    /// App Group write goes nowhere asks once rather than forever.
    private var hasGrantedConsentThisSession = false

    /// - Parameters:
    ///   - recorder: the microphone. Injected for the same reason `routing`
    ///     is — a CI simulator has neither one.
    ///   - silence: when a recording stops itself. Injected so a test can
    ///     reach the auto-stop without waiting ten seconds for it.
    ///   - drafts: the note the app is holding between launches. Injected so
    ///     a test writes to a suite of its own rather than the device's slot.
    ///   - isAppInForeground: whether the app is on screen at all. Only
    ///     `.background` counts as gone — a notification banner pulled over
    ///     the app makes it inactive, and the user is still watching. Injected
    ///     so a test can end a recording from a locked phone it hasn't got.
    init(
        routing: OrganizeRouting = OrganizeRouting(),
        log: DiagnosticsLog = .shared,
        locale: Locale = .current,
        recorder: any AudioRecording = AudioRecorderService(),
        silence: SilenceDetector.Configuration = .default,
        drafts: DraftStore = .shared,
        isAppInForeground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState != .background }
    ) {
        self.routing = routing
        self.log = log
        self.locale = locale
        self.recorder = recorder
        self.silence = silence
        self.drafts = drafts
        self.isAppInForeground = isAppInForeground
        self.silenceDetector = SilenceDetector(configuration: silence)

        self.recorder.onInterrupted = { [weak self] in
            self?.finishRecording(reason: .interrupted)
        }
    }

    // MARK: - Intents

    /// Puts the first-run screen up before anything else on an install that
    /// hasn't seen it. Told what TidyNote sends first, recorded second — the
    /// other order would be the app asking forgiveness.
    func showFirstRunIfNeeded() {
        // A restored draft is proof the question was answered before that note
        // was ever made — and it has the screen, so there is nothing to put
        // this in front of.
        guard case .idle = state else { return }
        if case .consentNeeded = route() {
            isShowingFirstRun = true
        }
    }

    /// Puts back the note the app was showing when it was last closed, so a
    /// finished tidy outlives the process that made it.
    func restoreDraftIfAvailable() {
        guard case .idle = state, let draft = drafts.load() else { return }
        state = .preview(draft)
    }

    func startCapture() {
        guard case .idle = state else { return }
        lifecycleTask?.cancel()
        lifecycleTask = Task { [weak self] in
            await self?.runCaptureLifecycle()
        }
    }

    /// A record request from outside the app: the widget, the Control Center
    /// control, Siri, a `tidynote://record` link. The screen could be showing
    /// anything at all, so it goes back to idle first and starts listening.
    ///
    /// Declined while something is still running or being held — a permission
    /// prompt, a recording, a tidy in flight, a recording waiting to send. Each
    /// of those is work the user hasn't finished with, and asking to record is
    /// not asking to throw it away; the app comes to the front showing it
    /// instead. The dead ends and the preview are fair game: they are screens
    /// the user has already been shown, with nothing left running behind them.
    ///
    /// The kept note survives either way. It is in the draft slot, and the slot
    /// is only overwritten when the next note arrives — so a recording started
    /// over the top of a restored draft, and then abandoned, still leaves the
    /// draft to come back to.
    func startQuickCapture() {
        // The first-run screen is a question the user hasn't answered yet.
        // Recording behind it would be the app answering for them.
        guard !isShowingFirstRun else { return }

        switch state {
        case .idle:
            break
        case .preview, .failed, .unavailable:
            abandonCapture()
            state = .idle
        case .requestingPermissions, .recording, .uploading, .organizing, .readyToSend:
            return
        }

        startCapture()
    }

    /// User-initiated stop. Auto-stop (silence/hard cap) and interruption
    /// both route through the same `finishRecording()`.
    func stopRecording() {
        finishRecording(reason: .manual)
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

    /// "Cancel" during the wait. The tidy stops; the recording does not go
    /// with it. Cancelling is a decision about the wait, not about what the
    /// user said, so the file stays and "Send" picks it up again.
    ///
    /// The cancelled run unwinds afterwards. `OrganizeRun` turns cancellation
    /// into "nothing to show", which is what keeps it from painting a failure
    /// over this screen.
    func cancelTidy() {
        switch state {
        case .uploading, .organizing:
            guard let recording else { return }
            organizeTask?.cancel()
            organizeTask = nil
            state = .readyToSend(duration: recording.duration)
        default:
            break
        }
    }

    /// "Send" from the ready-to-send screen: the upload the cancel
    /// interrupted, with the recording it kept.
    func send() {
        guard case .readyToSend = state else { return }
        startOrganize()
    }

    /// Re-reads the plan after the paywall closes. A subscription bought at the
    /// quota wall was bought to get past it, so the tidy that hit the wall runs
    /// again rather than making the user say it all over.
    func refreshPlan() {
        guard case .unavailable(.cloudQuotaExhausted) = state, routing.isPro else { return }
        startOrganize()
    }

    /// Abandons an in-progress or completed capture and returns to idle. The
    /// recording goes with it, and so does the kept note: the user has said
    /// they're done with both.
    func reset() {
        abandonCapture()
        drafts.clear()
        state = .idle
    }

    /// Everything `reset()` does except forget the kept note: tasks cancelled,
    /// the microphone stopped, the file on disk gone, the silence window fresh.
    /// The state is left alone — the caller says where it goes next.
    private func abandonCapture() {
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
        silenceDetector = SilenceDetector(configuration: silence)
    }

    // MARK: - Coming and going

    /// The app went behind the lock screen or another app. Recording carries
    /// on there; this only says so in the log, so a capture the user couldn't
    /// watch still leaves a trail on their device.
    func appWentToBackground() {
        guard case .recording = state else { return }
        log.recordEvent(source: .app, message: "Backgrounded while recording")
    }

    /// The app is back on screen. An audio session can be taken away without
    /// an interruption notification ever arriving, which would leave the meter
    /// turning over a microphone that stopped listening minutes ago. If that
    /// happened, end the recording here rather than let the screen lie.
    ///
    /// A recording that ended in the background is sitting in `.readyToSend`,
    /// and it stays there: the user reads what is waiting and taps Send.
    func appBecameActive() {
        guard case .recording = state else { return }
        log.recordEvent(source: .app, message: "Foregrounded while recording")
        guard !recorder.isRecording else { return }
        log.recordEvent(source: .app, message: "Recording session died in the background")
        finishRecording(reason: .interrupted)
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
        silenceDetector = SilenceDetector(configuration: silence)
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
                // Anything that ends a recording leaves `.recording` first, so
                // a state that isn't `.recording` means this loop's work is
                // over — not that this one sample should be skipped.
                guard case .recording = self.state else { break }
                let elapsed = self.clock.now - startedAt
                self.state = .recording(level: level, elapsed: elapsed)

                switch self.silenceDetector.evaluate(elapsed: elapsed, level: level) {
                case .continue:
                    break
                case .autoStopSilence:
                    self.finishRecording(reason: .autoStopSilence)
                case .hardCapReached:
                    self.finishRecording(reason: .autoStopHardCap)
                }
            }
        }
    }

    /// Stops recording (from a manual tap, auto-stop, an interruption, or the
    /// hard cap) and moves on to the upload — unless the app is behind the
    /// lock screen or another app, in which case the recording waits. The
    /// system suspends an app it can't see, so an upload started here would
    /// fail for a reason that has nothing to do with the user. The file is
    /// kept instead, and they send it when they come back.
    ///
    /// Idempotent — safe to call from more than one signal racing to end the
    /// same recording, because it runs start to finish without suspending and
    /// leaves the state somewhere other than `.recording` however it goes.
    private func finishRecording(reason: StopReason) {
        guard case .recording = state else { return }
        lastStopReason = reason

        levelTask?.cancel()
        levelTask = nil

        guard let finished = recorder.stop() else {
            state = .failed(.captureFailed(String(localized: "The recording didn't save. Try again.")))
            return
        }

        guard finished.duration >= Self.minimumDuration else {
            delete(finished)
            state = .failed(.emptyRecording)
            return
        }

        recording = finished

        guard isAppInForeground() else {
            log.recordEvent(source: .app, message: "Recording finished in the background; holding it to send")
            state = .readyToSend(duration: finished.duration)
            return
        }

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

    private func run(_ recording: CapturedRecording) async {
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
            // The note replaces the recording as the thing worth keeping: it
            // cost a tidy, and it is not saved anywhere else until the user
            // sends it to Apple Notes.
            drafts.save(outcome.note)
            state = .preview(outcome.note)
        case .failure(let failure):
            state = .unavailable(failure)
        case nil:
            // Cancelled — whoever cancelled has already moved the state on,
            // to idle for `reset()` or to ready-to-send for `cancelTidy()`.
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

    private func delete(_ recording: CapturedRecording) {
        try? FileManager.default.removeItem(at: recording.url)
    }
}
