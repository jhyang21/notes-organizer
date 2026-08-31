import Foundation
import NotesOrganizerKit
import Testing
@testable import NotesOrganizer

/// A microphone that does what the test tells it to. Every hook
/// `CaptureViewModel` uses is scripted: whether permission is granted, what
/// `start()` throws, the meter samples, and what `stop()` hands back.
@MainActor
private final class MockRecorder: AudioRecording {
    var onInterrupted: (() -> Void)?

    var permissionGranted = true
    var startError: (any Error)?
    /// What `stop()` hands back once a recording is running.
    var finished: CapturedRecording?

    private(set) var isRecording = false
    private(set) var startCount = 0
    private var levels: AsyncStream<Float>.Continuation?

    func requestPermission() async -> Bool { permissionGranted }

    func start() throws -> AsyncStream<Float> {
        if let startError { throw startError }
        startCount += 1
        isRecording = true
        let (stream, continuation) = AsyncStream<Float>.makeStream()
        levels = continuation
        return stream
    }

    func stop() -> CapturedRecording? {
        guard isRecording else { return nil }
        isRecording = false
        levels?.finish()
        levels = nil
        return finished
    }

    /// One meter sample, the way the real recorder's timer delivers them.
    func emit(_ level: Float) {
        levels?.yield(level)
    }
}

private extension SilenceDetector.Configuration {
    /// Stops on the first sample with nothing audible in it. The real window
    /// is ten seconds of wall clock, which is ten seconds no test should
    /// spend; the auto-stop path it reaches is the same one.
    static let stopsOnFirstSilence = SilenceDetector.Configuration(
        silenceWindow: .zero,
        minimumRecordingDuration: .zero
    )
}

private extension CaptureViewModel.State {
    var recordingLevel: Float? {
        guard case .recording(let level, _) = self else { return nil }
        return level
    }
}

@MainActor
@Suite("CaptureViewModel")
struct CaptureViewModelTests {
    private let note = OrganizedNote(
        title: "Kitchen quotes",
        sections: [NoteSection(heading: "Quotes", bullets: ["Bosch quoted 4,200"])]
    )

    // MARK: - Fixtures

    /// A real file on disk, so a test can tell whether the view model deleted
    /// the recording it was done with.
    private func makeRecordingFile(duration: TimeInterval = 3) throws -> CapturedRecording {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-test-\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: url)
        return CapturedRecording(url: url, duration: duration)
    }

    /// - Parameters:
    ///   - organizer: a `MockOrganizer` for a tidy that answers, a
    ///     `SlowOrganizer` for one a test wants to catch mid-wait.
    ///   - drafts: writes nowhere unless a test asks for a real slot. A test
    ///     that says nothing about drafts must not touch the one on the
    ///     machine running it.
    private func makeViewModel(
        recorder: MockRecorder,
        organizer: any NoteOrganizing & VoiceOrganizing,
        store: EntitlementStore,
        silence: SilenceDetector.Configuration = .default,
        drafts: DraftStore = DraftStore(defaults: nil)
    ) -> CaptureViewModel {
        CaptureViewModel(
            routing: OrganizeRouting(store: store, cloud: organizer),
            log: makeLog(),
            locale: Locale(identifier: "en_US"),
            recorder: recorder,
            silence: silence,
            drafts: drafts
        )
    }

    // MARK: - Starting

    @Test("granting the microphone starts a recording")
    func startsRecording() async throws {
        let defaults = try EphemeralDefaults()
        let recorder = MockRecorder()
        let viewModel = makeViewModel(
            recorder: recorder,
            organizer: MockOrganizer(result: note),
            store: makeStore(defaults)
        )

        viewModel.startCapture()
        try await waitUntil("the recording to start") { recorder.isRecording }

        #expect(viewModel.state.recordingLevel == 0)
        #expect(recorder.startCount == 1)
    }

    @Test("a meter sample moves the level on screen")
    func meterSamplesReachTheState() async throws {
        let defaults = try EphemeralDefaults()
        let recorder = MockRecorder()
        let viewModel = makeViewModel(
            recorder: recorder,
            organizer: MockOrganizer(result: note),
            store: makeStore(defaults)
        )

        viewModel.startCapture()
        try await waitUntil("the recording to start") { recorder.isRecording }
        recorder.emit(0.5)

        try await waitUntil("the sample to reach the state") { viewModel.state.recordingLevel == 0.5 }
    }

    @Test("a refused microphone is a failure, not a silent nothing")
    func permissionDeniedFails() async throws {
        let defaults = try EphemeralDefaults()
        let recorder = MockRecorder()
        recorder.permissionGranted = false
        let viewModel = makeViewModel(
            recorder: recorder,
            organizer: MockOrganizer(result: note),
            store: makeStore(defaults)
        )

        viewModel.startCapture()
        try await waitUntil("the failure") { viewModel.state == .failed(.microphonePermissionDenied) }

        #expect(recorder.startCount == 0)
    }

    @Test("a microphone that won't start says why")
    func startFailureCarriesTheReason() async throws {
        let defaults = try EphemeralDefaults()
        let recorder = MockRecorder()
        recorder.startError = AudioRecorderService.RecorderError.startFailed("The microphone didn't start.")
        let viewModel = makeViewModel(
            recorder: recorder,
            organizer: MockOrganizer(result: note),
            store: makeStore(defaults)
        )

        viewModel.startCapture()
        try await waitUntil("the failure") {
            viewModel.state == .failed(.captureFailed("The microphone didn't start."))
        }
    }

    // MARK: - Stopping

    @Test("stopping uploads the recording and lands on the note")
    func stopUploadsAndPreviews() async throws {
        let defaults = try EphemeralDefaults()
        let recording = try makeRecordingFile()
        let recorder = MockRecorder()
        recorder.finished = recording
        let organizer = MockOrganizer(result: note)
        let viewModel = makeViewModel(recorder: recorder, organizer: organizer, store: makeStore(defaults))

        viewModel.startCapture()
        try await waitUntil("the recording to start") { recorder.isRecording }
        viewModel.stopRecording()

        try await waitUntil("the note") { viewModel.state == .preview(note) }
        #expect(await organizer.receivedRecordings == [recording.url])
        // The note is here, so the recording has done its job.
        #expect(FileManager.default.fileExists(atPath: recording.url.path) == false)
    }

    @Test("a pause stops the recording on its own")
    func silenceAutoStops() async throws {
        let defaults = try EphemeralDefaults()
        let recording = try makeRecordingFile()
        let recorder = MockRecorder()
        recorder.finished = recording
        let organizer = MockOrganizer(result: note)
        let viewModel = makeViewModel(
            recorder: recorder,
            organizer: organizer,
            store: makeStore(defaults),
            silence: .stopsOnFirstSilence
        )

        viewModel.startCapture()
        try await waitUntil("the recording to start") { recorder.isRecording }
        recorder.emit(0)

        try await waitUntil("the note") { viewModel.state == .preview(note) }
        #expect(recorder.isRecording == false)
        #expect(await organizer.receivedRecordings == [recording.url])
    }

    @Test("an interruption ends the recording the same way a tap does")
    func interruptionFinishesTheRecording() async throws {
        let defaults = try EphemeralDefaults()
        let recording = try makeRecordingFile()
        let recorder = MockRecorder()
        recorder.finished = recording
        let viewModel = makeViewModel(
            recorder: recorder,
            organizer: MockOrganizer(result: note),
            store: makeStore(defaults)
        )

        viewModel.startCapture()
        try await waitUntil("the recording to start") { recorder.isRecording }
        recorder.onInterrupted?()

        try await waitUntil("the note") { viewModel.state == .preview(note) }
    }

    @Test("a recording that didn't save is a failure, not an empty upload")
    func missingFileFails() async throws {
        let defaults = try EphemeralDefaults()
        let recorder = MockRecorder()
        recorder.finished = nil
        let organizer = MockOrganizer(result: note)
        let viewModel = makeViewModel(recorder: recorder, organizer: organizer, store: makeStore(defaults))

        viewModel.startCapture()
        try await waitUntil("the recording to start") { recorder.isRecording }
        viewModel.stopRecording()

        #expect(viewModel.state == .failed(.captureFailed("The recording didn't save. Try again.")))
        #expect(await organizer.receivedRecordings.isEmpty)
    }

    @Test("a stray tap is thrown away rather than uploaded")
    func tooShortRecordingIsDiscarded() async throws {
        let defaults = try EphemeralDefaults()
        let recording = try makeRecordingFile(duration: 0.4)
        let recorder = MockRecorder()
        recorder.finished = recording
        let organizer = MockOrganizer(result: note)
        let viewModel = makeViewModel(recorder: recorder, organizer: organizer, store: makeStore(defaults))

        viewModel.startCapture()
        try await waitUntil("the recording to start") { recorder.isRecording }
        viewModel.stopRecording()

        #expect(viewModel.state == .failed(.emptyRecording))
        #expect(await organizer.receivedRecordings.isEmpty)
        #expect(FileManager.default.fileExists(atPath: recording.url.path) == false)
    }

    // MARK: - Retrying

    @Test("retrying after a failure sends the same recording again")
    func retryReusesTheRecording() async throws {
        let defaults = try EphemeralDefaults()
        let recording = try makeRecordingFile()
        let recorder = MockRecorder()
        recorder.finished = recording
        let organizer = MockOrganizer(error: .networkUnavailable)
        let viewModel = makeViewModel(recorder: recorder, organizer: organizer, store: makeStore(defaults))

        viewModel.startCapture()
        try await waitUntil("the recording to start") { recorder.isRecording }
        viewModel.stopRecording()
        try await waitUntil("the failure") { viewModel.state == .unavailable(.networkUnavailable) }

        await organizer.setOutcome(.success(note))
        viewModel.retry()
        try await waitUntil("the note") { viewModel.state == .preview(note) }

        // The same file both times: a retry sends what the user said, not a
        // request to say it again.
        #expect(await organizer.receivedRecordings == [recording.url, recording.url])
    }

    @Test("a recording with nothing in it isn't worth re-sending")
    func retryOnEmptyTranscriptStartsOver() async throws {
        let defaults = try EphemeralDefaults()
        let recording = try makeRecordingFile()
        let recorder = MockRecorder()
        recorder.finished = recording
        let organizer = MockOrganizer(error: .emptyTranscript)
        let viewModel = makeViewModel(recorder: recorder, organizer: organizer, store: makeStore(defaults))

        viewModel.startCapture()
        try await waitUntil("the recording to start") { recorder.isRecording }
        viewModel.stopRecording()
        try await waitUntil("the failure") { viewModel.state == .unavailable(.emptyTranscript) }

        viewModel.retry()

        #expect(viewModel.state == .idle)
        #expect(await organizer.receivedRecordings.count == 1)
        #expect(FileManager.default.fileExists(atPath: recording.url.path) == false)
    }

    // MARK: - Walls

    @Test("a spent quota is a wall, and nothing is uploaded into it")
    func quotaWallBlocksTheUpload() async throws {
        let defaults = try EphemeralDefaults()
        let recording = try makeRecordingFile()
        defer { try? FileManager.default.removeItem(at: recording.url) }
        let recorder = MockRecorder()
        recorder.finished = recording
        let organizer = MockOrganizer(result: note)
        let store = makeStore(defaults, remaining: 0)
        let viewModel = makeViewModel(recorder: recorder, organizer: organizer, store: store)

        viewModel.startCapture()
        try await waitUntil("the recording to start") { recorder.isRecording }
        viewModel.stopRecording()

        #expect(viewModel.state == .unavailable(.cloudQuotaExhausted))
        #expect(await organizer.receivedRecordings.isEmpty)
    }

    @Test("subscribing at the wall runs the tidy that hit it")
    func subscribingResumesTheBlockedTidy() async throws {
        let defaults = try EphemeralDefaults()
        let recording = try makeRecordingFile()
        let recorder = MockRecorder()
        recorder.finished = recording
        let organizer = MockOrganizer(result: note)
        let store = makeStore(defaults, remaining: 0)
        let viewModel = makeViewModel(recorder: recorder, organizer: organizer, store: store)

        viewModel.startCapture()
        try await waitUntil("the recording to start") { recorder.isRecording }
        viewModel.stopRecording()
        #expect(viewModel.state == .unavailable(.cloudQuotaExhausted))

        store.recordIsPro(true)
        viewModel.refreshPlan()

        try await waitUntil("the note") { viewModel.state == .preview(note) }
        #expect(await organizer.receivedRecordings == [recording.url])
    }

    @Test("an unanswered first run holds the recording back until it's answered")
    func consentHoldsTheUpload() async throws {
        let defaults = try EphemeralDefaults()
        let recording = try makeRecordingFile()
        let recorder = MockRecorder()
        recorder.finished = recording
        let organizer = MockOrganizer(result: note)
        let viewModel = makeViewModel(
            recorder: recorder,
            organizer: organizer,
            store: makeStore(defaults, consentGranted: false)
        )

        viewModel.startCapture()
        try await waitUntil("the recording to start") { recorder.isRecording }
        viewModel.stopRecording()

        #expect(viewModel.isShowingFirstRun)
        #expect(await organizer.receivedRecordings.isEmpty)

        viewModel.acceptFirstRun()

        try await waitUntil("the note") { viewModel.state == .preview(note) }
        #expect(viewModel.isShowingFirstRun == false)
        #expect(await organizer.receivedRecordings == [recording.url])
    }

    @Test("the first-run screen goes up only while the question is unanswered")
    func firstRunShowsOnlyWhenNeeded() throws {
        let defaults = try EphemeralDefaults()
        let unanswered = makeViewModel(
            recorder: MockRecorder(),
            organizer: MockOrganizer(result: note),
            store: makeStore(defaults, consentGranted: false)
        )
        unanswered.showFirstRunIfNeeded()
        #expect(unanswered.isShowingFirstRun)

        let answered = makeViewModel(
            recorder: MockRecorder(),
            organizer: MockOrganizer(result: note),
            store: makeStore(defaults)
        )
        answered.showFirstRunIfNeeded()
        #expect(answered.isShowingFirstRun == false)
    }

    // MARK: - Walking away

    @Test("walking away mid-tidy cancels it and keeps the screen at idle")
    func resetCancelsAnOrganizeInFlight() async throws {
        let defaults = try EphemeralDefaults()
        let recording = try makeRecordingFile()
        let recorder = MockRecorder()
        recorder.finished = recording
        let viewModel = makeViewModel(recorder: recorder, organizer: SlowOrganizer(), store: makeStore(defaults))

        viewModel.startCapture()
        try await waitUntil("the recording to start") { recorder.isRecording }
        viewModel.stopRecording()
        try await waitUntil("the upload") { viewModel.state == .uploading }

        viewModel.reset()
        #expect(viewModel.state == .idle)
        #expect(recorder.isRecording == false)
        #expect(FileManager.default.fileExists(atPath: recording.url.path) == false)

        // The cancelled run finishes after the reset. It must not paint a
        // failure over a screen that is already back at the start.
        try await Task.sleep(for: .milliseconds(50))
        #expect(viewModel.state == .idle)
    }

    // MARK: - Leaving the wait

    @Test("cancelling the wait gives up the tidy, not the recording")
    func cancelKeepsTheRecording() async throws {
        let defaults = try EphemeralDefaults()
        let recording = try makeRecordingFile(duration: 12)
        defer { try? FileManager.default.removeItem(at: recording.url) }
        let recorder = MockRecorder()
        recorder.finished = recording
        let viewModel = makeViewModel(recorder: recorder, organizer: SlowOrganizer(), store: makeStore(defaults))

        viewModel.startCapture()
        try await waitUntil("the recording to start") { recorder.isRecording }
        viewModel.stopRecording()
        try await waitUntil("the upload") { viewModel.state == .uploading }

        viewModel.cancelTidy()

        #expect(viewModel.state == .readyToSend(duration: 12))
        #expect(FileManager.default.fileExists(atPath: recording.url.path))

        // The cancelled run unwinds afterwards. It must not paint a failure
        // over a screen that is waiting to be sent.
        try await Task.sleep(for: .milliseconds(50))
        #expect(viewModel.state == .readyToSend(duration: 12))
    }

    @Test("sending after a cancel uploads the recording that was kept")
    func sendReusesTheKeptRecording() async throws {
        let defaults = try EphemeralDefaults()
        let recording = try makeRecordingFile(duration: 8)
        let recorder = MockRecorder()
        recorder.finished = recording
        let organizer = MockOrganizer(result: note)
        let viewModel = makeViewModel(recorder: recorder, organizer: organizer, store: makeStore(defaults))

        viewModel.startCapture()
        try await waitUntil("the recording to start") { recorder.isRecording }
        // Both calls run to completion before the organize task gets a turn,
        // so the cancel reliably lands on a tidy that hasn't started yet.
        viewModel.stopRecording()
        viewModel.cancelTidy()

        #expect(viewModel.state == .readyToSend(duration: 8))
        #expect(await organizer.receivedRecordings.isEmpty)

        viewModel.send()
        try await waitUntil("the note") { viewModel.state == .preview(note) }

        // The file the recorder made, not a new one: cancelling cost the
        // wait, not what the user said.
        #expect(await organizer.receivedRecordings == [recording.url])
    }

    // MARK: - Drafts

    @Test("a finished note is kept, so closing the app doesn't spend a tidy for nothing")
    func previewKeepsTheNote() async throws {
        let defaults = try EphemeralDefaults()
        let drafts = DraftStore(defaults: defaults.defaults)
        let recorder = MockRecorder()
        recorder.finished = try makeRecordingFile()
        let viewModel = makeViewModel(
            recorder: recorder,
            organizer: MockOrganizer(result: note),
            store: makeStore(defaults),
            drafts: drafts
        )

        viewModel.startCapture()
        try await waitUntil("the recording to start") { recorder.isRecording }
        viewModel.stopRecording()
        try await waitUntil("the note") { viewModel.state == .preview(note) }

        #expect(drafts.load() == note)
    }

    @Test("starting a new note lets the kept one go")
    func resetClearsTheDraft() async throws {
        let defaults = try EphemeralDefaults()
        let drafts = DraftStore(defaults: defaults.defaults)
        let recorder = MockRecorder()
        recorder.finished = try makeRecordingFile()
        let viewModel = makeViewModel(
            recorder: recorder,
            organizer: MockOrganizer(result: note),
            store: makeStore(defaults),
            drafts: drafts
        )

        viewModel.startCapture()
        try await waitUntil("the recording to start") { recorder.isRecording }
        viewModel.stopRecording()
        try await waitUntil("the note") { viewModel.state == .preview(note) }

        viewModel.reset()

        #expect(drafts.load() == nil)
    }

    @Test("a kept note is back on screen at the next launch")
    func draftIsRestored() throws {
        let defaults = try EphemeralDefaults()
        let drafts = DraftStore(defaults: defaults.defaults)
        drafts.save(note)

        let viewModel = makeViewModel(
            recorder: MockRecorder(),
            organizer: MockOrganizer(result: note),
            store: makeStore(defaults),
            drafts: drafts
        )
        viewModel.restoreDraftIfAvailable()

        #expect(viewModel.state == .preview(note))
    }

    @Test("nothing kept means nothing to put back")
    func noDraftLeavesTheScreenAtIdle() throws {
        let defaults = try EphemeralDefaults()
        let viewModel = makeViewModel(
            recorder: MockRecorder(),
            organizer: MockOrganizer(result: note),
            store: makeStore(defaults),
            drafts: DraftStore(defaults: defaults.defaults)
        )
        viewModel.restoreDraftIfAvailable()

        #expect(viewModel.state == .idle)
    }

    @Test("a restored draft doesn't reopen a question it already answers")
    func restoredDraftSkipsFirstRun() throws {
        let defaults = try EphemeralDefaults()
        let drafts = DraftStore(defaults: defaults.defaults)
        drafts.save(note)

        // Consent unwritten, as it would be on a device where the App Group
        // write went nowhere. The note is proof enough that it was granted.
        let viewModel = makeViewModel(
            recorder: MockRecorder(),
            organizer: MockOrganizer(result: note),
            store: makeStore(defaults, consentGranted: false),
            drafts: drafts
        )
        viewModel.restoreDraftIfAvailable()
        viewModel.showFirstRunIfNeeded()

        #expect(viewModel.state == .preview(note))
        #expect(viewModel.isShowingFirstRun == false)
    }
}
