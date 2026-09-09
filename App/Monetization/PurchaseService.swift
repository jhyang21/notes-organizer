import Foundation
import RevenueCat

/// What came back from asking the store to take a payment. A cancel is not a
/// failure — the user closed a sheet, and the paywall should say nothing about
/// it — so it gets a case of its own rather than an error to interpret.
enum PurchaseResult: Equatable, Sendable {
    case purchased(isPro: Bool)
    case cancelled
}

/// The two ways this app can ask the store for something it can't have.
/// Everything else the store refuses arrives as the SDK's own error and is
/// passed along unread.
enum PurchaseServiceError: Error, Equatable {
    /// The SDK was never started. Only reachable if the app's launch path
    /// changed, and worth a distinct error rather than a crash.
    case notConfigured
    /// A plan the paywall offered is no longer one the store knows about —
    /// an offering edited in the dashboard between the load and the tap.
    case planUnavailable
}

/// What `PurchasesController` asks of the App Store, and nothing more.
///
/// `AudioRecording` exists for the same reason: the rules worth testing — what
/// gets written to the App Group, which plan is preselected, what a restore
/// that finds nothing says — are the app's, not the SDK's, and a CI simulator
/// has no Apple Account to buy anything with and must reach no network.
///
/// Everything here returns plain value types. The SDK's own types stop at
/// `RevenueCatPurchaseService`, which is what keeps the paywall, its view
/// model and their tests free of it.
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

    /// What the store is selling right now, with live prices.
    ///
    /// - Returns: `nil` when the store has no current offering — nothing is
    ///   wrong, there is simply nothing to show.
    func currentOffer() async throws -> PaywallOffer?

    /// Which of these products this Apple Account may still start a free
    /// trial on. Never throws: an eligibility check that fails only means the
    /// paywall words its button the honest, unexcited way.
    func trialEligibility(for productIDs: [String]) async -> Set<String>

    /// Buys the plan by its product identifier — the same `id` the offer
    /// handed out, so a caller never holds an SDK object.
    func purchase(planID: String) async throws -> PurchaseResult
}

/// The real one.
@MainActor
final class RevenueCatPurchaseService: PurchaseService {
    /// RevenueCat's public SDK key. It identifies the app, not the user, and
    /// is meant to ship in clients — the secret key lives in the dashboard.
    private static let apiKey = "appl_TOxAKdSxotqcJNPNvdynaNmLIfn"

    /// The entitlement's lookup key in the TidyNote RevenueCat project.
    /// `nonisolated` because the `CustomerInfo` extension below reads it from
    /// outside the main actor; an immutable String is safe from anywhere.
    nonisolated static let proEntitlement = "pro"

    /// The packages behind the plans the last `currentOffer()` handed out.
    /// A purchase needs the SDK's own object, and the paywall only ever holds
    /// a product identifier, so the pairing is kept here.
    private var packagesByPlanID: [String: Package] = [:]

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

    func currentOffer() async throws -> PaywallOffer? {
        guard isConfigured else { throw PurchaseServiceError.notConfigured }

        let offerings = try await Purchases.shared.offerings()
        guard let offering = offerings.current else { return nil }

        var plans: [PaywallPlan] = []
        var packages: [String: Package] = [:]
        for package in offering.availablePackages {
            // A package the app has no card for — a lifetime purchase, a
            // six-month plan — is skipped rather than drawn wrong.
            guard let plan = Self.makePlan(from: package.storeProduct) else { continue }
            plans.append(plan)
            packages[plan.id] = package
        }

        packagesByPlanID = packages
        return PaywallOffer.make(from: plans)
    }

    func trialEligibility(for productIDs: [String]) async -> Set<String> {
        guard isConfigured, !productIDs.isEmpty else { return [] }

        let results = await Purchases.shared.checkTrialOrIntroDiscountEligibility(
            productIdentifiers: productIDs
        )
        // `.unknown` happens on a sandbox account's first launch. Only a plain
        // yes counts: promising a trial we can't give is worse than leaving
        // one unmentioned.
        return Set(results.filter { $0.value.status == .eligible }.keys)
    }

    func purchase(planID: String) async throws -> PurchaseResult {
        guard isConfigured else { throw PurchaseServiceError.notConfigured }
        guard let package = packagesByPlanID[planID] else {
            throw PurchaseServiceError.planUnavailable
        }

        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled { return .cancelled }
            return .purchased(isPro: result.customerInfo.isPro)
        } catch {
            // A cancel can arrive either way depending on where in the sheet
            // the user backed out, so both spellings mean the same thing here.
            guard Self.isCancellation(error) else { throw error }
            return .cancelled
        }
    }

    // MARK: - Mapping the SDK's world onto the app's

    /// One store product as a plan the paywall can draw, or `nil` for anything
    /// this app doesn't sell: a period other than one month or one year.
    private static func makePlan(from product: StoreProduct) -> PaywallPlan? {
        guard let subscriptionPeriod = product.subscriptionPeriod,
              subscriptionPeriod.value == 1 else { return nil }

        let period: PeriodUnit
        switch subscriptionPeriod.unit {
        case .month: period = .month
        case .year: period = .year
        default: return nil
        }

        let currencyCode = product.currencyCode ?? ""
        let pricePerMonth = PaywallPricing.pricePerMonth(product.price, period: period)
        // Computed from the price rather than read off the product: the SDK's
        // own per-month string is not offered for every product, and one
        // source for the number keeps the card and its VoiceOver label equal.
        let localizedPricePerMonth = pricePerMonth.map {
            PaywallPricing.format($0, formatter: product.priceFormatter, currencyCode: currencyCode)
        }

        var trialDays: Int?
        if let introductory = product.introductoryDiscount, introductory.paymentMode == .freeTrial,
           let unit = periodUnit(from: introductory.subscriptionPeriod.unit) {
            trialDays = PaywallPricing.days(unit: unit, value: introductory.subscriptionPeriod.value)
        }

        return PaywallPlan(
            id: product.productIdentifier,
            period: period,
            price: product.price,
            currencyCode: currencyCode,
            localizedPrice: product.localizedPriceString,
            localizedPricePerMonth: localizedPricePerMonth,
            trialDays: trialDays
        )
    }

    /// Unlike the plan's own period, a trial's can be any of the four.
    private static func periodUnit(from unit: SubscriptionPeriod.Unit) -> PeriodUnit? {
        switch unit {
        case .day: return .day
        case .week: return .week
        case .month: return .month
        case .year: return .year
        default: return nil
        }
    }

    /// Whether the store is telling us the user backed out. The SDK can hand
    /// this back as its own error type or as the bridged `NSError` underneath
    /// it, and neither one is worth an alert.
    private static func isCancellation(_ error: any Error) -> Bool {
        if let code = error as? ErrorCode {
            return code == .purchaseCancelledError
        }
        let bridged = error as NSError
        return bridged.domain.contains("RevenueCat")
            && bridged.code == ErrorCode.purchaseCancelledError.rawValue
    }
}

extension CustomerInfo {
    /// Whether TidyNote Pro is active right now. One place to ask, so the
    /// paywall, the restore button and the entitlement stream can't drift.
    var isPro: Bool {
        entitlements[RevenueCatPurchaseService.proEntitlement]?.isActive == true
    }
}
