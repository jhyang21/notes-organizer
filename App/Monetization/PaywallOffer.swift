import Foundation

/// How long one billing period lasts, in the app's own words rather than the
/// store SDK's. The paywall is drawn from these types, so keeping them plain
/// is what lets a test build an offer without a network, an Apple Account, or
/// RevenueCat linked into it.
enum PeriodUnit: Equatable, Sendable {
    case day
    case week
    case month
    case year
}

/// One thing the user can buy, already turned into the strings a view shows.
///
/// Every price here came from StoreKit through the store SDK and was
/// formatted in the storefront's own currency and conventions. Nothing in the
/// app ever writes a price down.
struct PaywallPlan: Equatable, Sendable, Identifiable {
    /// The App Store product identifier, which is also how the service finds
    /// the package to buy again later.
    let id: String
    let period: PeriodUnit
    let price: Decimal
    let currencyCode: String
    /// "$39.99" — the whole period's price, as the storefront writes it.
    let localizedPrice: String
    /// "$3.33" — what a year comes to per month, and `nil` when the plan is
    /// already monthly or shorter and the number would only repeat the line
    /// above it.
    let localizedPricePerMonth: String?
    /// The introductory free trial in days, or `nil` when the plan has none.
    /// Days rather than the store's own unit because "7-Day Free Trial" is
    /// what the button has to say, and the App Store stores that trial as one
    /// week.
    let trialDays: Int?
}

/// Everything the paywall needs to draw itself: what can be bought, which one
/// to put first, and how much the recommendation saves.
struct PaywallOffer: Equatable, Sendable {
    /// The recommendation first, so a view can render them in order without
    /// knowing why that order is what it is.
    let plans: [PaywallPlan]
    let recommendedPlanID: String?
    /// What the yearly plan saves against twelve months of the monthly one,
    /// as a whole percent. `nil` when there is nothing to compare, or when
    /// the yearly plan saves nothing.
    let savingsPercent: Int?

    /// Orders the plans, picks the recommendation and works out the saving.
    ///
    /// - Returns: `nil` when there is nothing to sell, which is the one case
    ///   the paywall can't draw and has to say so about.
    static func make(from plans: [PaywallPlan]) -> PaywallOffer? {
        guard !plans.isEmpty else { return nil }

        let ordered = plans
            .enumerated()
            .sorted { left, right in
                let leftRank = rank(left.element.period)
                let rightRank = rank(right.element.period)
                // The original order breaks ties, so two plans billed over the
                // same period stay in the order the store listed them.
                return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
            }
            .map(\.element)

        let yearly = ordered.first { $0.period == .year }
        let monthly = ordered.first { $0.period == .month }

        // A single plan is the choice, not the better one: recommending it
        // over nothing would put a "Best value" badge on the only card.
        let recommendedPlanID = ordered.count > 1 ? yearly?.id : nil

        var savingsPercent: Int?
        if let yearly, let monthly, yearly.currencyCode == monthly.currencyCode {
            savingsPercent = PaywallPricing.savingsPercent(
                monthly: monthly.price,
                yearly: yearly.price
            )
        }

        return PaywallOffer(
            plans: ordered,
            recommendedPlanID: recommendedPlanID,
            savingsPercent: savingsPercent
        )
    }

    /// Longest period first. Only `.month` and `.year` reach the paywall
    /// today; the other two are ranked so a plan the store adds later lands
    /// somewhere sensible rather than at random.
    private static func rank(_ period: PeriodUnit) -> Int {
        switch period {
        case .year: 0
        case .month: 1
        case .week: 2
        case .day: 3
        }
    }
}

/// The paywall's arithmetic, with nothing else in it. Prices are the one place
/// a rounding mistake reads as dishonesty, so every number the screen shows is
/// worked out here where a test can check it.
enum PaywallPricing {
    /// What a year costs against twelve of the monthly price, as a whole
    /// percent, rounded down — an understated saving is a promise the store
    /// can keep.
    ///
    /// - Returns: `nil` when the yearly plan saves nothing, so a paywall never
    ///   claims a saving of zero.
    static func savingsPercent(monthly: Decimal, yearly: Decimal) -> Int? {
        let twelveMonths = monthly * 12
        guard twelveMonths > 0 else { return nil }

        let saved = twelveMonths - yearly
        guard saved > 0 else { return nil }

        let fraction = NSDecimalNumber(decimal: saved / twelveMonths).doubleValue
        let percent = Int(floor(fraction * 100))
        return percent > 0 ? percent : nil
    }

    /// What one month of a plan comes to.
    ///
    /// - Returns: `nil` for a period a per-month line would only restate — a
    ///   monthly plan already says its own monthly price.
    static func pricePerMonth(_ price: Decimal, period: PeriodUnit) -> Decimal? {
        switch period {
        case .year: return price / 12
        case .month, .week, .day: return nil
        }
    }

    /// A price in the storefront's own words.
    ///
    /// The store's formatter is the right answer whenever there is one: it
    /// already knows the currency, the separators and where the symbol goes
    /// for the account's country. The two fallbacks exist because a derived
    /// price — a year divided by twelve — is a number the store never handed
    /// us a formatted string for.
    static func format(_ price: Decimal, formatter: NumberFormatter?, currencyCode: String) -> String {
        if let formatter, let formatted = formatter.string(from: NSDecimalNumber(decimal: price)) {
            return formatted
        }
        if !currencyCode.isEmpty {
            return price.formatted(.currency(code: currencyCode))
        }
        return price.formatted(.number.precision(.fractionLength(2)))
    }

    /// A trial length in days. The App Store stores a seven-day trial as one
    /// week, and "1-Week Free Trial" is not what the button should say.
    ///
    /// Months and years are the calendar's rough ones. No introductory offer
    /// in this app uses either, and a trial measured in months doesn't need
    /// the day count to be exact to read right.
    static func days(unit: PeriodUnit, value: Int) -> Int {
        switch unit {
        case .day: value
        case .week: value * 7
        case .month: value * 30
        case .year: value * 365
        }
    }
}
