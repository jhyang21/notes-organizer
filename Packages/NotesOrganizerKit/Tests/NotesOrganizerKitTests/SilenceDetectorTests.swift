import Testing
@testable import NotesOrganizerKit

@Suite("SilenceDetector")
struct SilenceDetectorTests {
    @Test("keeps recording before the minimum duration even with no activity")
    func continuesBeforeMinimumDuration() {
        var detector = SilenceDetector(configuration: .init(
            activityThreshold: 0.11,
            silenceWindow: .seconds(10),
            minimumRecordingDuration: .milliseconds(2500),
            hardCap: .seconds(300)
        ))

        #expect(detector.evaluate(elapsed: .zero, isActive: false) == .continue)
        #expect(detector.evaluate(elapsed: .milliseconds(1000), isActive: false) == .continue)
        #expect(detector.evaluate(elapsed: .milliseconds(2499), isActive: false) == .continue)
    }

    @Test("auto-stops once silence exceeds the window past the minimum duration")
    func autoStopsAfterSilenceWindow() {
        var detector = SilenceDetector(configuration: .init(
            activityThreshold: 0.11,
            silenceWindow: .seconds(10),
            minimumRecordingDuration: .milliseconds(2500),
            hardCap: .seconds(300)
        ))

        // No activity ever recorded, so lastActivity stays at zero.
        #expect(detector.evaluate(elapsed: .milliseconds(2500), isActive: false) == .continue)
        #expect(detector.evaluate(elapsed: .milliseconds(9999), isActive: false) == .continue)
        #expect(detector.evaluate(elapsed: .seconds(10), isActive: false) == .autoStopSilence)
    }

    @Test("activity resets the silence window")
    func activityResetsWindow() {
        var detector = SilenceDetector(configuration: .init(
            activityThreshold: 0.11,
            silenceWindow: .seconds(10),
            minimumRecordingDuration: .milliseconds(2500),
            hardCap: .seconds(300)
        ))

        #expect(detector.evaluate(elapsed: .seconds(3), isActive: true) == .continue)
        // 9.9s after the last activity — still inside the window.
        #expect(detector.evaluate(elapsed: .milliseconds(12_900), isActive: false) == .continue)
        // 10s after the last activity (elapsed 3s) — now silent long enough.
        #expect(detector.evaluate(elapsed: .seconds(13), isActive: false) == .autoStopSilence)
    }

    @Test("evaluate(elapsed:level:) applies the activity threshold")
    func levelConvenienceAppliesThreshold() {
        var detector = SilenceDetector(configuration: .init(
            activityThreshold: 0.11,
            silenceWindow: .seconds(10),
            minimumRecordingDuration: .milliseconds(2500),
            hardCap: .seconds(300)
        ))

        // Below threshold never counts as activity, so silence accumulates
        // from elapsed zero and auto-stops at the window boundary.
        #expect(detector.evaluate(elapsed: .seconds(5), level: 0.05) == .continue)
        #expect(detector.evaluate(elapsed: .seconds(10), level: 0.05) == .autoStopSilence)

        var activeDetector = SilenceDetector(configuration: .init(
            activityThreshold: 0.11,
            silenceWindow: .seconds(10),
            minimumRecordingDuration: .milliseconds(2500),
            hardCap: .seconds(300)
        ))
        #expect(activeDetector.evaluate(elapsed: .seconds(5), level: 0.5) == .continue)
        #expect(activeDetector.evaluate(elapsed: .seconds(10), level: 0.5) == .continue)
    }

    @Test("hard cap fires even while actively speaking")
    func hardCapOverridesActivity() {
        var detector = SilenceDetector(configuration: .init(
            activityThreshold: 0.11,
            silenceWindow: .seconds(10),
            minimumRecordingDuration: .milliseconds(2500),
            hardCap: .seconds(300)
        ))

        #expect(detector.evaluate(elapsed: .seconds(299), isActive: true) == .continue)
        #expect(detector.evaluate(elapsed: .seconds(300), isActive: true) == .hardCapReached)
    }

    @Test("default configuration matches the plan's tuned thresholds")
    func defaultConfigurationValues() {
        let configuration = SilenceDetector.Configuration.default
        #expect(configuration.activityThreshold == 0.11)
        #expect(configuration.silenceWindow == .seconds(10))
        #expect(configuration.minimumRecordingDuration == .milliseconds(2500))
        #expect(configuration.hardCap == .seconds(300))
    }
}
