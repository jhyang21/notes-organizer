import Foundation

/// A finished recording: where it is, and how long it ran. The file outlives
/// the recorder — deleting it is the caller's business, because the caller is
/// the one that knows whether the note came back.
struct CapturedRecording {
    let url: URL
    let duration: TimeInterval
}

/// What `CaptureViewModel` asks of a microphone, and nothing more.
///
/// `AudioRecorderService` is the only real implementation. The seam exists so
/// the capture state machine can be driven on a CI simulator, which has no
/// microphone to grant permission for and nothing to meter.
@MainActor
protocol AudioRecording: AnyObject {
    /// Fired when the OS interrupts the session — a phone call, say.
    var onInterrupted: (() -> Void)? { get set }

    /// Whether the microphone is running right now. Asked on return from the
    /// background, where a session can die without notifying anyone.
    var isRecording: Bool { get }

    func requestPermission() async -> Bool
    func start() throws -> AsyncStream<Float>
    func stop() -> CapturedRecording?
}
