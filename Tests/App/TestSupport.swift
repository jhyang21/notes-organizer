import Foundation
import NotesOrganizerKit
import Testing
@testable import NotesOrganizer

/// Stands in for the App Group suite, so nothing a test logs reaches the
/// simulator's shared storage. A lock rather than an actor because
/// `DiagnosticsStorage` is synchronous.
final class InMemoryDiagnosticsStorage: DiagnosticsStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        lock.withLock { values[key] }
    }

    func setData(_ data: Data?, forKey key: String) {
        lock.withLock {
            if let data {
                values[key] = data
            } else {
                values.removeValue(forKey: key)
            }
        }
    }
}

func makeLog() -> DiagnosticsLog {
    DiagnosticsLog(storage: InMemoryDiagnosticsStorage())
}

/// A `UserDefaults` suite of this test's own, removed when the object goes.
/// The app and the extension both read one shared suite in the field; a test
/// that used it would be reading whatever the last test wrote.
final class EphemeralDefaults {
    let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        let suiteName = "NotesOrganizerTests-\(UUID().uuidString)"
        self.suiteName = suiteName
        self.defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// A store with the plan already in the state a test needs.
///
/// - Parameter remaining: tidies left this month, or `nil` to leave the plan
///   unwritten — which is what a fresh install looks like.
func makeStore(
    _ defaults: EphemeralDefaults,
    consentGranted: Bool = true,
    remaining: Int? = nil
) -> EntitlementStore {
    let store = EntitlementStore(defaults: defaults.defaults)
    store.setCloudConsentGranted(consentGranted)
    if let remaining {
        store.recordQuota(
            used: max(0, PlanState.freeMonthlyLimit - remaining),
            limit: PlanState.freeMonthlyLimit,
            month: currentMonthKey(),
            isPro: false
        )
    }
    return store
}

/// The month label `EntitlementStore` counts against, worked out the way it
/// does: UTC, so a machine in any time zone reads its own quota.
func currentMonthKey() -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    let parts = calendar.dateComponents([.year, .month], from: Date())
    return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
}

// MARK: - The store

/// An App Store that does what the test tells it to. The stream is built up
/// front, so a test can send an update without racing the controller's
/// subscription — an `AsyncStream` holds what it was given until someone
/// iterates it.
///
/// Shared by the controller's tests and the paywall's, which is the point:
/// one mock means the two can't disagree about what the store does.
@MainActor
final class MockPurchaseService: PurchaseService {
    var isConfigured = false
    var restoreResult: Result<Bool, any Error> = .success(false)
    var offerResult: Result<PaywallOffer?, any Error> = .success(nil)
    /// Which products this Apple Account may still start a trial on. Answered
    /// as the real service does — only the ones actually asked about.
    var eligiblePlanIDs: Set<String> = []
    var purchaseResult: Result<PurchaseResult, any Error> = .success(.purchased(isPro: true))

    private(set) var configuredAppUserID: String?
    /// Every plan a purchase was attempted for, in order, whether or not the
    /// store then said yes.
    private(set) var purchasedPlanIDs: [String] = []

    private let updates: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init() {
        let made = AsyncStream<Bool>.makeStream()
        updates = made.stream
        continuation = made.continuation
    }

    func configure(appUserID: String) {
        isConfigured = true
        configuredAppUserID = appUserID
    }

    func entitlementUpdates() -> AsyncStream<Bool> { updates }

    func restore() async throws -> Bool { try restoreResult.get() }

    func currentOffer() async throws -> PaywallOffer? { try offerResult.get() }

    func trialEligibility(for productIDs: [String]) async -> Set<String> {
        eligiblePlanIDs.intersection(productIDs)
    }

    func purchase(planID: String) async throws -> PurchaseResult {
        purchasedPlanIDs.append(planID)
        return try purchaseResult.get()
    }

    /// One word from the store about the customer, as the SDK's stream would
    /// deliver it.
    func send(isPro: Bool) {
        continuation.yield(isPro)
    }
}

/// A store call that failed for a reason only a log should ever repeat.
struct StoreUnreachable: LocalizedError {
    var errorDescription: String? { "The App Store returned 503 (service unavailable)" }
}

/// Answers whatever the test sets, so a test can say "airplane mode" or
/// "back online" without a real network to take away. Defaults to online, the
/// same as a device with a normal connection, so a test that says nothing
/// about it behaves like every test written before this mock existed.
@MainActor
final class MockConnectivity: ConnectivityChecking, @unchecked Sendable {
    var isOnlineValue = true

    func isOnline() async -> Bool { isOnlineValue }
}

/// The two products TidyNote sells, by the identifiers the App Store knows
/// them as.
let annualPlanID = "tidynote.pro.annual"
let monthlyPlanID = "tidynote.pro.monthly"

/// One plan, priced from a string so the decimal is exactly the one the store
/// would have sent — a `Decimal` written as a float literal is not.
func makePlan(
    id: String,
    period: PeriodUnit,
    price: String,
    localizedPrice: String,
    localizedPricePerMonth: String? = nil,
    trialDays: Int? = 7
) -> PaywallPlan {
    PaywallPlan(
        id: id,
        period: period,
        price: Decimal(string: price) ?? 0,
        currencyCode: "USD",
        localizedPrice: localizedPrice,
        localizedPricePerMonth: localizedPricePerMonth,
        trialDays: trialDays
    )
}

/// What the store is really selling: $4.99 a month or $39.99 a year, both with
/// a seven-day trial. The flags are for the two shapes that are harder to get
/// on a device — a plan with no trial left, and an offering with one plan in
/// it.
func makeOffer(
    trialDays: Int? = 7,
    includesAnnual: Bool = true,
    includesMonthly: Bool = true
) -> PaywallOffer {
    var plans: [PaywallPlan] = []
    if includesMonthly {
        plans.append(makePlan(
            id: monthlyPlanID,
            period: .month,
            price: "4.99",
            localizedPrice: "$4.99",
            trialDays: trialDays
        ))
    }
    if includesAnnual {
        plans.append(makePlan(
            id: annualPlanID,
            period: .year,
            price: "39.99",
            localizedPrice: "$39.99",
            localizedPricePerMonth: "$3.33",
            trialDays: trialDays
        ))
    }
    // Monthly first on the way in, so every caller also proves the offer puts
    // the recommendation first on the way out.
    return PaywallOffer.make(from: plans)
        ?? PaywallOffer(plans: [], recommendedPlanID: nil, savingsPercent: nil)
}

/// Never answers. Stands in for a tidy still in flight, so a test can catch
/// a view model mid-wait or walk away from one; the sleep is what a
/// cancellation lands on.
struct SlowOrganizer: NoteOrganizing, VoiceOrganizing {
    func organize(_ text: String) async throws -> OrganizedNote {
        try await wait()
    }

    func organize(audioAt url: URL, durationSeconds: Double, locale: Locale) async throws -> OrganizedNote {
        try await wait()
    }

    private func wait() async throws -> OrganizedNote {
        try await Task.sleep(for: .seconds(60))
        return OrganizedNote(title: "Never", sections: [])
    }
}

struct WaitTimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "Timed out waiting for \(what)." }
}

/// Waits for something the object under test does on its own — a meter sample
/// landing, an organize coming back. Polls instead of sleeping a fixed
/// interval, so a passing test costs a millisecond or two and a stuck one
/// still ends.
@MainActor
func waitUntil(
    _ what: String,
    within limit: Duration = .seconds(5),
    _ condition: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while !condition() {
        guard clock.now < deadline else { throw WaitTimedOut(what: what) }
        try await Task.sleep(for: .milliseconds(1))
    }
}
