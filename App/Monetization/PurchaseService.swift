import Foundation
import RevenueCat

/// What `PurchasesController` asks of the App Store, and nothing more.
///
/// `AudioRecording` exists for the same reason: the rules worth testing — what
/// gets written to the App Group, what a restore that finds nothing says — are
/// the app's, not the SDK's, and a CI simulator has no Apple Account to buy
/// anything with and must reach no network.
@MainActor
protocol PurchaseService: AnyObject {
    /// Whether the SDK is already running. Configuring twice is a runtime
    /// warning at best, and SwiftUI can run an `App` initializer again.
    var isConfigured: Bool { get }

    func configure(appUserID: String)

    /// Whether Pro is active: once when the stream opens, and again every time
    /// the store's view of the customer changes — a purchase, a lapse, a
    /// subscription bought on another iPhone.
    func entitlementUpdates() -> AsyncStream<Bool>

    /// - Returns: whether this Apple Account owns Pro.
    func restore() async throws -> Bool
}

/// The real one.
@MainActor
final class RevenueCatPurchaseService: PurchaseService {
    /// RevenueCat's public SDK key. It identifies the app, not the user, and
    /// is meant to ship in clients — the secret key lives in the dashboard.
    private static let apiKey = "appl_TOxAKdSxotqcJNPNvdynaNmLIfn"

    /// The entitlement's lookup key in the TidyNote RevenueCat project.
    static let proEntitlement = "pro"

    var isConfigured: Bool { Purchases.isConfigured }

    /// The app user ID is handed over at configure time, never after. It comes
    /// from the App Group, so it is the same string the share extension reads
    /// and the same one the organize endpoint counts against — and because it
    /// exists before the SDK does, RevenueCat never mints an anonymous ID that
    /// a later `logIn` would have to reconcile.
    func configure(appUserID: String) {
        Purchases.configure(
            with: Configuration.Builder(withAPIKey: Self.apiKey)
                .with(appUserID: appUserID)
                .build()
        )
    }

    func entitlementUpdates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let task = Task {
                for await customerInfo in Purchases.shared.customerInfoStream {
                    continuation.yield(customerInfo.isPro)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func restore() async throws -> Bool {
        try await Purchases.shared.restorePurchases().isPro
    }
}

extension CustomerInfo {
    /// Whether TidyNote Pro is active right now. One place to ask, so the
    /// paywall, the restore button and the entitlement stream can't drift.
    var isPro: Bool {
        entitlements[RevenueCatPurchaseService.proEntitlement]?.isActive == true
    }
}
