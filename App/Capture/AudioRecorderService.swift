import AVFoundation
import Foundation
import NotesOrganizerKit

/// Records the microphone to a file and meters it while it runs. The file is
/// what gets uploaded — this device transcribes nothing — so the settings are
/// chosen for a speech service rather than for listening back: mono AAC at
/// 16 kHz, about a megabyte for five minutes, which is the rate a transcriber
/// resamples to anyway.
///
/// App-target only. AVFoundation and hardware permissions aren't part of
/// `NotesOrganizerKit`, whose code stays testable on CI simulators that have
/// no microphone; the parts of a recording's life that can be decided without
/// one — its name, and when a leftover is stale — live there as
/// `RecordingFile`.
@MainActor
final class AudioRecorderService: AudioRecording {
    /// `LocalizedError` because the reason goes on a screen: the default
    /// description for a bare Swift error is a type name and a case number,
    /// which is no use to anyone holding a phone.
    enum RecorderError: LocalizedError, Equatable {
        case alreadyRecording
        case startFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: "A recording is already running."
            case .startFailed(let reason): reason
            }
        }
    }

    /// Fired when the OS interrupts the session — a phone call, say. Unlike
    /// the engine this replaced, nothing is torn down here first: the caller
    /// stops the recording itself, and stopping is what saves the file.
    var onInterrupted: (() -> Void)?

    /// Ten a second. Fast enough that the meter looks alive and a pause is
    /// noticed promptly, slow enough to cost nothing.
    private static let meterInterval = Duration.milliseconds(100)

    private static let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ]

    private var recorder: AVAudioRecorder?
    private var levelContinuation: AsyncStream<Float>.Continuation?
    private var meterTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    /// The length the recording had reached when it was last seen running,
    /// sampled by the meter. `currentTime` reads zero once the recorder has
    /// stopped — including when the system stopped it — so this is the only
    /// place a lost session's length survives.
    private var lastMeteredDuration: TimeInterval = 0

    /// Asked of `AVAudioRecorder` rather than remembered, because the two
    /// answers differ exactly when it matters: the system can take the session
    /// away without saying so, and a flag set in `start()` would go on
    /// insisting the microphone was live.
    var isRecording: Bool { recorder?.isRecording ?? false }

    // MARK: - Permission

    /// Requests microphone permission via the iOS 17+ `AVAudioApplication` API.
    func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    // MARK: - Recording

    /// Starts recording to a fresh file in the temporary directory and returns
    /// a normalized (0...1) level for metering, sampled ten times a second.
    /// The stream finishes when `stop()` is called.
    func start() throws -> AsyncStream<Float> {
        // The object, not `isRecording`: a recorder whose session died is
        // still one this hasn't been told to let go of.
        guard recorder == nil else { throw RecorderError.alreadyRecording }

        let session = AVAudioSession.sharedInstance()
        // `.notifyOthersOnDeactivation` is a `setActive(options:)` flag, not a
        // category option — it's applied in `stop()` below, not here.
        //
        // This category plus the `audio` background mode in Info.plist is the
        // whole background contract: an active session keeps the process
        // running, so recording and metering carry on when the user switches
        // apps or locks the phone. The ten-second silence stop and the
        // five-minute cap apply there too — a pocketed recording ends on its
        // own, out of sight.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(RecordingFile.newName())

        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: Self.settings)
        } catch {
            throw RecorderError.startFailed(error.localizedDescription)
        }
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw RecorderError.startFailed("The microphone didn't start. Try again.")
        }

        self.recorder = recorder
        lastMeteredDuration = 0

        let (levels, continuation) = AsyncStream<Float>.makeStream()
        levelContinuation = continuation

        // `Task { }` in a `@MainActor` method inherits that isolation, which is
        // what this wants: `AVAudioRecorder` is read from one place only.
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.meterInterval)
                guard !Task.isCancelled, let self, let recorder = self.recorder else { return }
                // Only while it is genuinely running: a stopped recorder
                // reports zero, which would erase the length it reached.
                if recorder.isRecording {
                    self.lastMeteredDuration = recorder.currentTime
                }
                recorder.updateMeters()
                continuation.yield(Self.normalizedLevel(recorder.averagePower(forChannel: 0)))
            }
        }

        observeInterruptions()
        return levels
    }

    /// Stops recording and hands back the finished file, or `nil` if there was
    /// nothing to stop. The file stays on disk either way.
    ///
    /// Keyed on the recorder object rather than on `isRecording`, so a session
    /// the system took away still yields its file: everything said before it
    /// died is in there, and a partial note beats an error message.
    func stop() -> CapturedRecording? {
        guard let recorder else { return nil }

        let duration = recorder.isRecording ? recorder.currentTime : lastMeteredDuration
        let recording = CapturedRecording(url: recorder.url, duration: duration)
        recorder.stop()
        self.recorder = nil

        meterTask?.cancel()
        meterTask = nil
        levelContinuation?.finish()
        levelContinuation = nil
        removeInterruptionObserver()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        return recording
    }

    // MARK: - Leftovers

    /// Deletes the recordings a previous run left behind — a tidy the user
    /// walked away from, or a launch that never came back. Called once at
    /// startup, off any user's path.
    ///
    /// `nonisolated` and synchronous: it lists one directory and unlinks a
    /// file or two, and running it before the first screen appears is worth
    /// more than the microseconds it costs.
    nonisolated static func sweepStaleRecordings(now: Date = Date()) {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }

        let found = names.compactMap { name -> RecordingFile? in
            guard RecordingFile.isRecording(name) else { return nil }
            let attributes = try? manager.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            // No modification date means nothing can be said about its age, so
            // it is left alone rather than guessed at.
            guard let modifiedAt = attributes?[.modificationDate] as? Date else { return nil }
            return RecordingFile(name: name, modifiedAt: modifiedAt)
        }

        for file in RecordingFile.stale(among: found, now: now) {
            try? manager.removeItem(at: directory.appendingPathComponent(file.name))
        }
    }

    // MARK: - Interruptions

    private func observeInterruptions() {
        // The notification closure isn't statically MainActor-isolated (its
        // type is a plain `(Notification) -> Void`), so the hop is explicit
        // rather than relying on `queue: .main`, which only picks a dispatch
        // queue, not an actor.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard
                let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: typeValue),
                type == .began
            else { return }

            Task { @MainActor [weak self] in
                self?.onInterrupted?()
            }
        }
    }

    private func removeInterruptionObserver() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
    }

    // MARK: - Metering

    /// Maps the recorder's average power to a 0...1 level. It reports dBFS on
    /// the same scale the old engine tap computed by hand, so the silence
    /// floor stays where it was at -60 dB and `SilenceDetector`'s threshold
    /// keeps meaning what it meant.
    private static func normalizedLevel(_ decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        return max(0, min(1, (decibels + 60) / 60))
    }
}
