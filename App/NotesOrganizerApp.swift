import SwiftUI

@main
struct NotesOrganizerApp: App {
    /// RevenueCat wants the app user ID before it configures, and the paywall
    /// wants offerings ready before the user can reach Settings — so this
    /// happens at launch rather than at the first sight of a paywall.
    ///
    /// The sweep is here for the opposite reason: a recording left behind by a
    /// tidy nobody came back to should go before the user does anything else,
    /// and launch is the one moment we know no recording is in flight.
    ///
    /// The unit tests are hosted by this app, so a test run launches it for
    /// real. RevenueCat is skipped there — a test that reaches the network is
    /// not a test. The sweep stays: it unlinks stale temporary files and
    /// talks to nothing.
    init() {
        if !Self.isRunningTests {
            PurchasesBootstrap.configure()
        }
        AudioRecorderService.sweepStaleRecordings()
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some Scene {
        WindowGroup {
            CaptureScreen()
        }
    }
}
