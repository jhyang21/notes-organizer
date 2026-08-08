import Foundation
import NotesOrganizerKit
import RevenueCat

/// Starts RevenueCat once per launch and keeps `EntitlementStore` in step with
/// what it says about the subscription.
///
/// The app user ID is handed over at configure time, never after. It comes
/// from the App Group, so it is the same string the share extension reads and
/// the same one the organize endpoint counts against — and because it exists
/// before the SDK does, RevenueCat never mints an anonymous ID that a later
/// `logIn` would have to reconcile.
///
/// Nothing here decides whether a premium tidy is allowed. The server re-checks
/// entitlement on every call; what the store learns from this file only drives
/// what the UI says about the plan.
enum PurchasesBootstrap {
    /// RevenueCat's public SDK key. It identifies the app, not the user, and
    /// is meant to ship in clients — the secret key lives in the dashboard.
    private static let apiKey = "appl_TOxAKdSxotqcJNPNvdynaNmLIfn"

    /// The entitlement's lookup key in the TidyNote RevenueCat project.
    static let proEntitlement = "pro"

    /// Safe to call more than once: the second call returns without touching
    /// the SDK. That matters because SwiftUI may run an `App` initializer or a
    /// `.task` again, and configuring twice is a runtime warning at best.
    static func configure() {
        guard !Purchases.isConfigured else { return }

        Purchases.configure(
            with: Configuration.Builder(withAPIKey: apiKey)
                .with(appUserID: EntitlementStore.shared.appUserID())
                .build()
        )

        mirrorEntitlement()
    }

    /// Follows the SDK's own view of the customer for the life of the process,
    /// so a purchase, a restore, an expiry, or a subscription bought on another
    /// device all land in the shared store without anyone asking. Detached
    /// because it outlives any one screen and touches no UI.
    private static func mirrorEntitlement() {
        Task.detached(priority: .utility) {
            for await customerInfo in Purchases.shared.customerInfoStream {
                EntitlementStore.shared.recordIsPro(customerInfo.isPro)
            }
        }
    }
}

extension CustomerInfo {
    /// Whether TidyNote Pro is active right now. One place to ask, so the
    /// paywall, the restore button and the background stream can't drift.
    var isPro: Bool {
        entitlements[PurchasesBootstrap.proEntitlement]?.isActive == true
    }
}
