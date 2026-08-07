import AVFoundation
import Foundation
import Speech

/// One tick of transcript state: the still-changing tail of the current
/// utterance, and everything finalized so far.
struct TranscriptUpdate: Sendable, Equatable {
    var volatileText: String
    var finalizedText: String

    /// Live view for the UI: finalized text with the in-progress tail
    /// appended, so the transcript never visibly shrinks as words finalize.
    var displayText: String {
        finalizedText.isEmpty ? volatileText : finalizedText + " " + volatileText
    }
}

enum TranscriptionServiceError: Error, Equatable {
    case localeNotSupported
    case alreadyStarted
}

/// Wraps iOS 26's on-device `SpeechAnalyzer` + `SpeechTranscriber` to turn a
/// stream of audio buffers into live transcript updates. App-target only:
/// the model this drives isn't present on CI simulators, so nothing here is
/// unit-tested — `CaptureViewModel` drives it and owns the parts that are.
///
/// NOTE: this is a best-effort mapping of Apple's WWDC25 "Bring advanced
/// speech-to-text to your app with SpeechAnalyzer" sample onto this app's
/// needs. The exact `Speech` API surface is verified by CI compiling
/// against the real iOS 26 SDK; see the M4 PR description for any spots
/// where the real signatures differed from this sketch.
@MainActor
final class TranscriptionService {
    let locale: Locale
    let transcriber: SpeechTranscriber

    private let analyzer: SpeechAnalyzer
    private let inputSequence: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Error>?

    private(set) var finalizedTranscript = ""
    private(set) var volatileTranscript = ""

    init(locale: Locale = .current) {
        self.locale = locale
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputSequence = stream
        self.inputContinuation = continuation
    }

    /// Feeds one captured buffer into the transcriber. Call from
    /// `AudioCaptureService`'s buffer stream while recording.
    func append(_ buffer: AVAudioPCMBuffer) {
        inputContinuation.yield(AnalyzerInput(buffer: buffer))
    }

    /// Starts the analyzer and returns a stream of transcript updates. The
    /// stream finishes once `finish()` or `cancel()` drains it.
    func start() throws -> AsyncStream<TranscriptUpdate> {
        guard resultsTask == nil else { throw TranscriptionServiceError.alreadyStarted }

        let (updateStream, updateContinuation) = AsyncStream<TranscriptUpdate>.makeStream()

        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in self.transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalizedTranscript = self.finalizedTranscript.isEmpty
                            ? text
                            : self.finalizedTranscript + " " + text
                        self.volatileTranscript = ""
                    } else {
                        self.volatileTranscript = text
                    }
                    updateContinuation.yield(
                        TranscriptUpdate(volatileText: self.volatileTranscript, finalizedText: self.finalizedTranscript)
                    )
                }
            } catch {
                // The results sequence throws only if analysis itself
                // failed; `finish()`/`cancel()` end it cleanly instead.
            }
            updateContinuation.finish()
        }

        analyzerTask = Task { [analyzer, inputSequence] in
            try await analyzer.start(inputSequence: inputSequence)
        }

        return updateStream
    }

    /// Stops feeding audio and waits for the analyzer to finalize whatever
    /// is left in flight, returning the full finalized transcript.
    func finish() async -> String {
        inputContinuation.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        return finalizedTranscript
    }

    /// Tears down without waiting for finalization — used on interruption
    /// or when the user discards a capture.
    func cancel() {
        inputContinuation.finish()
        resultsTask?.cancel()
        analyzerTask?.cancel()
        Task { [analyzer] in
            await analyzer.cancelAndFinishNow()
        }
    }
}
