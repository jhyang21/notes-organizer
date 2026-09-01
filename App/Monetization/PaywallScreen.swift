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
    @Environment(\.dismiss) private var dismiss
    @Environment(PurchasesController.self) private var purchases

    var body: some View {
        PaywallView(displayCloseButton: true)
            .onPurchaseCompleted { customerInfo in
                purchases.recordEntitlement(isPro: customerInfo.isPro)
                dismiss()
            }
            .onRestoreCompleted { customerInfo in
                purchases.recordEntitlement(isPro: customerInfo.isPro)
                // A restore that finds nothing leaves the sheet up: the user
                // came here to subscribe, and closing on them would read as
                // though it had worked.
                if customerInfo.isPro {
                    dismiss()
                }
            }
    }
}
