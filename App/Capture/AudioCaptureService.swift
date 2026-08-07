import AVFoundation
import Foundation

// `AVAudioPCMBuffer` isn't marked `Sendable` in this SDK, so handing one
// through `AsyncStream<AVAudioPCMBuffer>` — even as a value's single, final
// use — can't be proven data-race-free by Swift 6's region checker. It's
// safe to assert here: `installTap` hands the tap block a buffer it
// uniquely owns for that call (the engine doesn't retain or mutate it
// afterward), so there's no live alias left behind to race against once
// it's yielded to the stream.
extension AVAudioPCMBuffer: @unchecked @retroactive Sendable {}

/// Captures microphone audio via `AVAudioEngine`, emitting raw PCM buffers
/// for `TranscriptionService` and a normalized (0...1) RMS level stream for
/// UI metering. App-target only: AVFoundation and hardware permissions
/// aren't part of `NotesOrganizerKit`, whose model-adjacent code stays
/// testable on CI simulators that have no microphone.
@MainActor
final class AudioCaptureService {
    enum CaptureError: Error, Equatable {
        case alreadyRecording
        case engineStartFailed(String)
    }

    /// Fired when the OS interrupts the session (e.g. a phone call). The
    /// engine has already been torn down by the time this fires — the
    /// caller only needs to move its own state machine to a stopped state.
    var onInterrupted: (() -> Void)?

    private let engine = AVAudioEngine()
    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var levelContinuation: AsyncStream<Float>.Continuation?
    private var interruptionObserver: NSObjectProtocol?
    private(set) var isRecording = false

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

    /// Starts capture. Returns two streams: raw PCM buffers (feed straight
    /// into `TranscriptionService.append(_:)`) and a normalized RMS level
    /// for metering. Both streams finish when `stop()` is called or an
    /// interruption ends the session.
    func start() throws -> (buffers: AsyncStream<AVAudioPCMBuffer>, levels: AsyncStream<Float>) {
        guard !isRecording else { throw CaptureError.alreadyRecording }

        let session = AVAudioSession.sharedInstance()
        // `.notifyOthersOnDeactivation` is a `setActive(options:)` flag, not a
        // category option — it's applied in `stop()` below, not here.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        let (bufferStream, bufferContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        let (levelStream, levelContinuation) = AsyncStream<Float>.makeStream()
        self.bufferContinuation = bufferContinuation
        self.levelContinuation = levelContinuation

        // Explicitly typed `@Sendable`: `AVAudioNodeTapBlock` isn't itself
        // marked `@Sendable`, so a closure literal written inline here would
        // otherwise infer @MainActor isolation from this method's context
        // (SE-0316) — wrong, since the tap actually fires on a realtime
        // audio thread. The explicit annotation makes it nonisolated instead,
        // and it captures only the local continuations (Sendable value
        // types), not `self`.
        // `AsyncStream.Continuation.yield(_:)` takes `sending Element`, which
        // hands `buffer` off to whatever isolation domain consumes the
        // stream — so the RMS read has to happen *before* the yield below,
        // not after; reusing `buffer` post-yield is exactly the data race
        // the compiler is (correctly) rejecting when the order is reversed.
        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            if let level = AudioCaptureService.normalizedRMSLevel(buffer) {
                levelContinuation.yield(level)
            }
            bufferContinuation.yield(buffer)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: tapBlock)

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.bufferContinuation = nil
            self.levelContinuation = nil
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }

        isRecording = true
        observeInterruptions()
        return (bufferStream, levelStream)
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        bufferContinuation?.finish()
        levelContinuation?.finish()
        bufferContinuation = nil
        levelContinuation = nil
        removeInterruptionObserver()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func observeInterruptions() {
        // The notification closure itself isn't statically MainActor-isolated
        // (its type is a plain `(Notification) -> Void`), so `stop()` — a
        // MainActor-isolated method — can't be called from it directly under
        // Swift 6 strict concurrency. Hop explicitly instead of relying on
        // `queue: .main`, which only picks a dispatch queue, not an actor.
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
                guard let self else { return }
                self.stop()
                self.onInterrupted?()
            }
        }
    }

    private func removeInterruptionObserver() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
    }

    /// Maps RMS amplitude to a 0...1 level using the same dB-normalized
    /// curve as the Relora reference implementation (silence floor at -60 dB).
    /// `nonisolated`: static members of a `@MainActor` type are MainActor-
    /// isolated by default, but this is called from the nonisolated tap
    /// block above, off the main actor.
    private nonisolated static func normalizedRMSLevel(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        let samples = channelData[0]
        var sum: Float = 0
        for index in 0..<frameCount {
            let sample = samples[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))
        let db = rms > 0 ? 20 * log10(rms) : -160
        return max(0, min(1, (db + 60) / 60))
    }
}
