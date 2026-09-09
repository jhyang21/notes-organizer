import Foundation
import Testing
@testable import NotesOrganizer

/// The paywall's arithmetic. A price is the one thing on the screen a user
/// could hold the app to, so every number it shows is worked out here and
/// checked here — no device, no Apple Account, no network.
@Suite("PaywallPricing")
struct PaywallPricingTests {
    // MARK: - The saving

    @Test("the yearly saving is the one TidyNote's own prices imply")
    func savingsForTheRealPrices() throws {
        let monthly = try #require(Decimal(string: "4.99"))
        let yearly = try #require(Decimal(string: "39.99"))

        #expect(PaywallPricing.savingsPercent(monthly: monthly, yearly: yearly) == 33)
    }

    /// 2 saved out of 12 is 16.6%. A paywall that rounded it up would be
    /// claiming a saving the store doesn't give.
    @Test("a saving is rounded down, never up")
    func savingsRoundDown() throws {
        let monthly = try #require(Decimal(string: "1.00"))
        let yearly = try #require(Decimal(string: "10.00"))

        #expect(PaywallPricing.savingsPercent(monthly: monthly, yearly: yearly) == 16)
    }

    @Test("a yearly plan that saves nothing has no saving to show")
    func noSavingIsNil() throws {
        let monthly = try #require(Decimal(string: "1.00"))
        let sameMoney = try #require(Decimal(string: "12.00"))
        let dearer = try #require(Decimal(string: "15.00"))
        let yearly = try #require(Decimal(string: "39.99"))

        #expect(PaywallPricing.savingsPercent(monthly: monthly, yearly: sameMoney) == nil)
        #expect(PaywallPricing.savingsPercent(monthly: monthly, yearly: dearer) == nil)
        #expect(PaywallPricing.savingsPercent(monthly: 0, yearly: yearly) == nil)
    }

    // MARK: - Per month

    @Test("a year divided into months is the number the card shows")
    func pricePerMonthForAYear() throws {
        let yearly = try #require(Decimal(string: "39.99"))

        #expect(PaywallPricing.pricePerMonth(yearly, period: .year) == Decimal(string: "3.3325"))
    }

    /// A monthly plan already states its monthly price; repeating it beside
    /// itself would read as two different numbers.
    @Test("a monthly plan has no per-month line")
    func pricePerMonthForAMonth() throws {
        let monthly = try #require(Decimal(string: "4.99"))

        #expect(PaywallPricing.pricePerMonth(monthly, period: .month) == nil)
        #expect(PaywallPricing.pricePerMonth(monthly, period: .week) == nil)
    }

    // MARK: - Formatting

    @Test("the store's own formatter is used when there is one")
    func formatWithTheStoreFormatter() throws {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.currencyCode = "USD"

        let price = try #require(Decimal(string: "39.99"))

        #expect(PaywallPricing.format(price, formatter: formatter, currencyCode: "USD") == "$39.99")
    }

    /// The fallbacks only have to be readable and in the right currency —
    /// the exact symbol placement is the running device's business, so this
    /// asks for the digits rather than a whole string.
    @Test("a price still reads as money without the store's formatter")
    func formatWithoutTheStoreFormatter() throws {
        let price = try #require(Decimal(string: "39.99"))

        let withCurrency = PaywallPricing.format(price, formatter: nil, currencyCode: "USD")
        #expect(withCurrency.contains("39"))
        #expect(withCurrency.contains("99"))

        let bare = PaywallPricing.format(price, formatter: nil, currencyCode: "")
        #expect(bare.contains("39"))
        #expect(bare.contains("99"))
    }

    // MARK: - Trial lengths

    /// The App Store stores TidyNote's seven-day trial as one week, and
    /// "1-Week Free Trial" is not what the button should say.
    @Test("a trial is measured in days whatever unit the store used")
    func trialDays() {
        #expect(PaywallPricing.days(unit: .week, value: 1) == 7)
        #expect(PaywallPricing.days(unit: .day, value: 3) == 3)
        #expect(PaywallPricing.days(unit: .month, value: 1) == 30)
        #expect(PaywallPricing.days(unit: .year, value: 1) == 365)
    }
}

@Suite("PaywallOffer")
struct PaywallOfferTests {
    @Test("the recommendation comes first, whatever order the store listed")
    func ordering() {
        let offer = makeOffer()

        #expect(offer.plans.map(\.id) == [annualPlanID, monthlyPlanID])
        #expect(offer.recommendedPlanID == annualPlanID)
        #expect(offer.savingsPercent == 33)
    }

    /// One plan is the choice, not the better one — a "Best value" badge on
    /// the only card is a comparison with nothing.
    @Test("a single plan is recommended over nothing")
    func singlePlan() {
        let offer = makeOffer(includesAnnual: false)

        #expect(offer.plans.map(\.id) == [monthlyPlanID])
        #expect(offer.recommendedPlanID == nil)
        #expect(offer.savingsPercent == nil)
    }

    @Test("a yearly plan with no monthly one to beat shows no saving")
    func savingNeedsBothPlans() {
        let offer = makeOffer(includesMonthly: false)

        #expect(offer.plans.map(\.id) == [annualPlanID])
        #expect(offer.savingsPercent == nil)
    }

    @Test("an offering with nothing in it is no offer at all")
    func emptyOffer() {
        #expect(PaywallOffer.make(from: []) == nil)
    }
}
