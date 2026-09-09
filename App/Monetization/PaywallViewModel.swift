import Foundation
import Observation

/// Everything the paywall knows and every sentence it says. The screen reads
/// this and draws it; it works out nothing of its own.
///
/// That split is the point. Which plan is preselected, whether the button
/// offers a trial or a subscription, what the small print underneath says —
/// these are the parts of a paywall that can quietly become untrue, and none
/// of them needs a device, an Apple Account or a network to check here.
@MainActor
@Observable
final class PaywallViewModel {
    /// Where the screen is between opening and having something to sell.
    /// Connectivity is checked first because a phone in airplane mode gets a
    /// dead-end that says so, rather than the store's own timeout.
    enum Phase: Equatable {
        case checkingConnection
        case offline
        case loading
        /// Online, and the store either had nothing to sell or did not answer.
        case unavailable
        case ready(PaywallOffer)
    }

    /// What brought the user here, which changes one line of copy: someone who
    /// just hit the monthly limit is owed a sentence about the tidy they were
    /// in the middle of.
    enum Origin: Equatable {
        case general
        case quotaWall
    }

    /// One shape for every alert this screen can raise — a failed purchase, a
    /// restore that found nothing, a restore that failed.
    struct StoreAlert: Equatable {
        let title: String
        let message: String
    }

    private(set) var phase: Phase = .checkingConnection
    private(set) var selectedPlanID: String?
    private(set) var trialEligiblePlanIDs: Set<String> = []
    private(set) var alert: StoreAlert?
    /// Settable so SwiftUI can bind the alert to it.
    var isShowingAlert = false

    /// Flips true on a purchase or a restore that actually found Pro — the
    /// screen's haptic fires on this, not on the sheet appearing or closing.
    private(set) var didUnlockPro = false

    /// Set once the screen has done its job. The view watches it and calls
    /// `dismiss`, which is the one thing a view model can't do itself.
    private(set) var shouldDismiss = false

    let origin: Origin

    @ObservationIgnored private let purchases: PurchasesController
    @ObservationIgnored private let connectivity: any ConnectivityChecking

    /// A purchase or a restore is in flight. Both disable the whole footer:
    /// two store calls at once is a race the user can start by accident.
    var isBusy: Bool { purchases.isPurchasing || purchases.isRestoring }

    var isPurchasing: Bool { purchases.isPurchasing }

    init(
        purchases: PurchasesController,
        origin: Origin = .general,
        connectivity: any ConnectivityChecking = ConnectivityMonitor.shared
    ) {
        self.purchases = purchases
        self.origin = origin
        self.connectivity = connectivity
    }

    // MARK: - Loading

    /// Connection, then prices, then trial eligibility — and only then
    /// `.ready`. Eligibility decides what the button says, so a screen that
    /// arrived before it would change its own call to action a moment after
    /// the user had read it.
    func load() async {
        phase = .checkingConnection

        guard await connectivity.isOnline() else {
            phase = .offline
            return
        }

        phase = .loading

        let offer: PaywallOffer?
        do {
            offer = try await purchases.loadOffer()
        } catch {
            phase = .unavailable
            return
        }

        guard let offer, !offer.plans.isEmpty else {
            phase = .unavailable
            return
        }

        trialEligiblePlanIDs = await purchases.trialEligibility(for: offer.plans.map(\.id))
        selectedPlanID = offer.recommendedPlanID ?? offer.plans.first?.id
        phase = .ready(offer)
    }

    /// The offline dead end's Try Again, and the only way back from it.
    func retry() async {
        await load()
    }

    // MARK: - Choosing

    func select(_ planID: String) {
        selectedPlanID = planID
    }

    var offer: PaywallOffer? {
        switch phase {
        case .ready(let offer): return offer
        case .checkingConnection, .offline, .loading, .unavailable: return nil
        }
    }

    var selectedPlan: PaywallPlan? {
        offer?.plans.first { $0.id == selectedPlanID }
    }

    func isRecommended(_ plan: PaywallPlan) -> Bool {
        plan.id == offer?.recommendedPlanID
    }

    func isSelected(_ plan: PaywallPlan) -> Bool {
        plan.id == selectedPlanID
    }

    /// Whether the selected plan can still start a free trial on this Apple
    /// Account. Both halves have to hold: an account that has used its trial
    /// is offered the subscription in plain words instead.
    var isTrialEligible: Bool {
        guard let plan = selectedPlan, plan.trialDays != nil else { return false }
        return trialEligiblePlanIDs.contains(plan.id)
    }

    // MARK: - Copy

    var supportingLine: String {
        switch origin {
        case .general:
            String(localized: "Every ramble and every messy note comes back organized, as often as you need.")
        case .quotaWall:
            String(localized: "You've used this month's free tidies. Go Pro and the note you were tidying picks up where it left off.")
        }
    }

    /// What the one big button says. It names the price when there is no trial
    /// to offer, because a button that only said "Subscribe" would be asking
    /// the user to remember which card they had tapped.
    var callToAction: String {
        guard let plan = selectedPlan else { return "" }

        if isTrialEligible, let days = plan.trialDays {
            return String(localized: "Start \(days)-Day Free Trial")
        }
        return String(localized: "Subscribe for \(priceLine(for: plan))")
    }

    /// The line under the button. Everything Apple asks a paywall to say, and
    /// nothing it doesn't: how long the trial is, what happens after it, that
    /// it renews, and where to stop it.
    var billingLine: String {
        guard let plan = selectedPlan else { return "" }

        let price = priceLine(for: plan)
        if isTrialEligible, let days = plan.trialDays {
            return String(localized: "\(days)-day free trial, then \(price). Renews automatically. Cancel anytime in Settings.")
        }
        return String(localized: "\(price), renews automatically. Cancel anytime in Settings.")
    }

    func title(for plan: PaywallPlan) -> String {
        switch plan.period {
        case .year: String(localized: "Yearly")
        case .month: String(localized: "Monthly")
        case .week, .day: plan.localizedPrice
        }
    }

    /// "$39.99/year". The card's own price, and the one the button repeats.
    func priceLine(for plan: PaywallPlan) -> String {
        switch plan.period {
        case .year: String(localized: "\(plan.localizedPrice)/year")
        case .month: String(localized: "\(plan.localizedPrice)/month")
        case .week, .day: plan.localizedPrice
        }
    }

    /// "$3.33/mo", or nothing when the plan is already billed monthly.
    func pricePerMonthLine(for plan: PaywallPlan) -> String? {
        guard let perMonth = plan.localizedPricePerMonth else { return nil }
        return String(localized: "\(perMonth)/mo")
    }

    /// "Save 33%", shown only on the recommendation and only when there is a
    /// monthly plan to have saved it against.
    var savingsLine: String? {
        guard let percent = offer?.savingsPercent else { return nil }
        return String(localized: "Save \((Double(percent) / 100).formatted(.percent))")
    }

    /// One sentence per card, because a card is one choice: VoiceOver reading
    /// "Yearly", "$39.99 per year", "$3.33 per month" as three stops makes the
    /// user assemble the offer themselves.
    func accessibilityLabel(for plan: PaywallPlan) -> String {
        var parts = [title(for: plan)]

        switch plan.period {
        case .year: parts.append(String(localized: "\(plan.localizedPrice) per year"))
        case .month: parts.append(String(localized: "\(plan.localizedPrice) per month"))
        case .week, .day: parts.append(plan.localizedPrice)
        }

        if let perMonth = plan.localizedPricePerMonth {
            parts.append(String(localized: "\(perMonth) per month"))
        }

        if isRecommended(plan) {
            if let savingsLine { parts.append(savingsLine) }
            parts.append(String(localized: "Best value"))
        }

        return parts.joined(separator: ", ")
    }

    // MARK: - Buying

    func purchase() async {
        guard let planID = selectedPlanID else { return }

        let outcome = await purchases.purchase(planID: planID)

        switch outcome {
        case .purchased(let isPro):
            didUnlockPro = isPro
            // The sheet closes either way. The store took the payment, and
            // leaving the paywall up would read as though it hadn't.
            shouldDismiss = true
        case .cancelled:
            break
        case .failed:
            show(title: outcome.title, message: outcome.message)
        }
    }

    func restore() async {
        let outcome = await purchases.restore()

        switch outcome {
        case .restored:
            didUnlockPro = true
            shouldDismiss = true
        case .nothingToRestore, .failed:
            // A restore that finds nothing leaves the sheet up: the user came
            // here to subscribe, and closing on them would read as though it
            // had worked.
            show(title: outcome.title, message: outcome.message)
        }
    }

    private func show(title: String, message: String) {
        alert = StoreAlert(title: title, message: message)
        isShowingAlert = true
    }
}
