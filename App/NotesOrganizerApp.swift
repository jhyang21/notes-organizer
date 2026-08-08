import SwiftUI

@main
struct NotesOrganizerApp: App {
    /// RevenueCat wants the app user ID before it configures, and the paywall
    /// wants offerings ready before the user can reach Settings — so this
    /// happens at launch rather than at the first sight of a paywall.
    init() {
        PurchasesBootstrap.configure()
    }

    var body: some Scene {
        WindowGroup {
            CaptureScreen()
        }
    }
}
