import Foundation

/// Pure silence/duration policy for voice capture: decides when a recording
/// should auto-stop from inactivity, or has hit its hard time cap. No I/O —
/// the caller feeds it the elapsed recording time and whether that instant
/// counted as speech activity (an audio level above threshold) and reads back
/// a decision. Kept in the package, unlike `AudioRecorderService` and
/// `CaptureViewModel`, because it has no AVFoundation dependency and is fully
/// unit-testable on CI.
public struct SilenceDetector: Sendable {
    public struct Configuration: Sendable {
        public var activityThreshold: Float
        public var silenceWindow: Duration
        public var minimumRecordingDuration: Duration
        public var hardCap: Duration

        public init(
            activityThreshold: Float = 0.11,
            silenceWindow: Duration = .seconds(10),
            minimumRecordingDuration: Duration = .milliseconds(2500),
            hardCap: Duration = .seconds(300)
        ) {
            self.activityThreshold = activityThreshold
            self.silenceWindow = silenceWindow
            self.minimumRecordingDuration = minimumRecordingDuration
            self.hardCap = hardCap
        }

        public static let `default` = Configuration()
    }

    public enum Decision: Equatable, Sendable {
        /// Keep recording.
        case `continue`
        /// No activity for `silenceWindow`, and past `minimumRecordingDuration` — stop.
        case autoStopSilence
        /// Elapsed time reached `hardCap` — stop regardless of activity.
        case hardCapReached
    }

    private let configuration: Configuration
    private var lastActivity: Duration = .zero

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// A level sample from the metering stream. Convenience over
    /// `evaluate(elapsed:isActive:)` that applies `activityThreshold` itself.
    public mutating func evaluate(elapsed: Duration, level: Float) -> Decision {
        evaluate(elapsed: elapsed, isActive: level > configuration.activityThreshold)
    }

    /// Call once per meter tick or transcript update, in increasing
    /// `elapsed` order, with whether this tick counts as speech activity.
    public mutating func evaluate(elapsed: Duration, isActive: Bool) -> Decision {
        if isActive {
            lastActivity = elapsed
        }

        if elapsed >= configuration.hardCap {
            return .hardCapReached
        }

        guard elapsed >= configuration.minimumRecordingDuration else {
            return .continue
        }

        if elapsed - lastActivity >= configuration.silenceWindow {
            return .autoStopSilence
        }

        return .continue
    }
}
