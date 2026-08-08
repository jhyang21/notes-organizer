import NotesOrganizerKit
import RevenueCat
import RevenueCatUI
import SwiftUI

/// TidyNote Pro, as a sheet. The prices, the copy and the layout come from the
/// current offering in the RevenueCat dashboard, so the store's paywall can be
/// re-cut without shipping a build; this file only says what happens after.
///
/// What happens after is the same for a purchase and a successful restore:
/// write the entitlement to the App Group — the extension has no SDK and only
/// learns about Pro this way — and get out of the user's way.
struct PaywallScreen: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PaywallView(displayCloseButton: true)
            .onPurchaseCompleted { customerInfo in
                EntitlementStore.shared.recordIsPro(customerInfo.isPro)
                dismiss()
            }
            .onRestoreCompleted { customerInfo in
                EntitlementStore.shared.recordIsPro(customerInfo.isPro)
                // A restore that finds nothing leaves the sheet up: the user
                // came here to subscribe, and closing on them would read as
                // though it had worked.
                if customerInfo.isPro {
                    dismiss()
                }
            }
    }
}
