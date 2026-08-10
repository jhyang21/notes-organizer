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
    init() {
        PurchasesBootstrap.configure()
        AudioRecorderService.sweepStaleRecordings()
    }

    var body: some Scene {
        WindowGroup {
            CaptureScreen()
        }
    }
}
