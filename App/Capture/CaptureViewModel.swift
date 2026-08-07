import AVFoundation
import Foundation
import NotesOrganizerKit
import Observation

/// Reasons a capture can't produce a note, on top of `OrganizeFailure` (M3)
/// covering everything upstream of the organizer: permissions, model-asset
/// download, and the audio pipeline itself.
enum CaptureFailure: Equatable {
    case microphonePermissionDenied
    case assetsUnsupported
    case assetDownloadFailed(String)
    case captureFailed(String)
    case emptyRecording
    case organizeFailed(OrganizeFailure)
}

/// Drives the capture flow end to end: idle → requestingPermissions →
/// downloadingAssets → recording → organizing → preview → saved, or
/// failed at any step. Owns `AudioCaptureService`, `TranscriptionService`,
/// and `SpeechAssetManager`; the organizer is injected via `NoteOrganizing`
/// so M5 can swap `MockOrganizer` for the real on-device organizer without
/// touching this type.
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
        case saved
        case failed(CaptureFailure)
    }

    private(set) var state: State = .idle

    private let organizer: NoteOrganizing
    private let locale: Locale
    private let audioCapture: AudioCaptureService
    private let transcription: TranscriptionService
    private let assetManager: SpeechAssetManager
    private let clock = ContinuousClock()

    private var silenceDetector = SilenceDetector()
    private var lifecycleTask: Task<Void, Never>?
    private var recordingTasks: [Task<Void, Never>] = []
    private var isFinishingRecording = false

    init(organizer: NoteOrganizing = MockOrganizer(result: OrganizedNote()), locale: Locale = .current) {
        self.organizer = organizer
        self.locale = locale
        self.audioCapture = AudioCaptureService()
        self.transcription = TranscriptionService(locale: locale)
        self.assetManager = SpeechAssetManager()

        audioCapture.onInterrupted = { [weak self] in
            self?.finishRecording()
        }
    }

    // MARK: - Intents

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

    /// Abandons an in-progress or completed capture and returns to idle —
    /// used by "discard" / "record again" affordances in the UI (M5 wires
    /// the actual buttons; this just resets the machine).
    func reset() {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        recordingTasks.forEach { $0.cancel() }
        recordingTasks = []
        isFinishingRecording = false
        transcription.cancel()
        audioCapture.stop()
        silenceDetector = SilenceDetector()
        state = .idle
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

        state = .organizing
        do {
            let note = try await organizer.organize(trimmed)
            state = .preview(note)
        } catch let failure as OrganizeFailure {
            state = .failed(.organizeFailed(failure))
        } catch {
            state = .failed(.organizeFailed(.modelNotReady(reason: error.localizedDescription)))
        }
    }
}
