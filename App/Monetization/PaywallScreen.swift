import NotesOrganizerKit
import RevenueCat
import RevenueCatUI
import SwiftUI

/// TidyNote Pro, as a sheet. The prices, the copy and the layout come from the
/// current offering in the RevenueCat dashboard, so the store's paywall can be
/// re-cut without shipping a build; this file only says what happens after.
///
/// What happens after is the same for a purchase and a successful restore:
/// hand the answer to `PurchasesController`, which is where the entitlement is
/// written, and get out of the user's way.
struct PaywallScreen: View {
    /// One shape for both a failed purchase and a failed restore's alert —
    /// the copy differs, the plumbing doesn't need to.
    private struct StoreAlert {
        let title: String
        let message: String
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(PurchasesController.self) private var purchases

    private let connectivity: any ConnectivityChecking

    /// `nil` while the first check is still running — a frame at most.
    @State private var isOnline: Bool?
    @State private var alert: StoreAlert?
    @State private var isShowingAlert = false

    /// Flips true on a purchase or a restore that actually found Pro — the
    /// haptic below fires on that, not on the sheet appearing or closing.
    @State private var didUnlockPro = false

    init(connectivity: any ConnectivityChecking = ConnectivityMonitor.shared) {
        self.connectivity = connectivity
    }

    var body: some View {
        Group {
            switch isOnline {
            case nil: ProgressView()
            case true?: paywall
            case false?: offlineView
            }
        }
        .task { isOnline = await connectivity.isOnline() }
        .alert(alert?.title ?? "", isPresented: $isShowingAlert, presenting: alert) { _ in
            Button("OK") {}
        } message: { Text($0.message) }
        .sensoryFeedback(.success, trigger: didUnlockPro) { _, new in new }
    }

    private var paywall: some View {
        PaywallView(displayCloseButton: true)
            .onPurchaseCompleted { customerInfo in
                purchases.recordEntitlement(isPro: customerInfo.isPro)
                didUnlockPro = customerInfo.isPro
                dismiss()
            }
            .onRestoreCompleted { customerInfo in
                purchases.recordEntitlement(isPro: customerInfo.isPro)
                // A restore that finds nothing leaves the sheet up: the user
                // came here to subscribe, and closing on them would read as
                // though it had worked.
                if customerInfo.isPro {
                    didUnlockPro = true
                    dismiss()
                } else {
                    let outcome = PurchasesController.RestoreOutcome.nothingToRestore
                    show(title: outcome.title, message: outcome.message)
                }
            }
            .onPurchaseFailure { error in
                let failure = purchases.report(.purchase, error: error)
                show(title: failure.title, message: failure.message)
            }
            .onRestoreFailure { error in
                let failure = purchases.report(.restore, error: error)
                show(title: failure.title, message: failure.message)
            }
    }

    /// Not `UnavailableView`: its copy is about a tidy, and this dead end is
    /// about the store.
    private var offlineView: some View {
        NoticeView(
            symbol: "wifi.slash",
            title: String(localized: "You're offline"),
            message: String(localized: "TidyNote Pro needs a connection to show prices and take a payment. Try again when you're back online.")
        ) {
            VStack(spacing: 12) {
                Button("Try Again") {
                    Task { isOnline = await connectivity.isOnline() }
                }
                .buttonStyle(.borderedProminent)

                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func show(title: String, message: String) {
        alert = StoreAlert(title: title, message: message)
        isShowingAlert = true
    }
}
