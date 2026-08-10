import Foundation
import Testing
@testable import NotesOrganizerKit

/// Three outcomes, two gates, and the order they run in. Everything the app
/// promises about the free plan is decided here, so every combination that can
/// reach it has a row.
@Suite("RoutingPolicy")
struct RoutingPolicyTests {
    private func route(
        isPro: Bool = false,
        cloudRemaining: Int? = 5,
        consentGranted: Bool = true
    ) -> RoutingPolicy.Route {
        RoutingPolicy.route(isPro: isPro, cloudRemaining: cloudRemaining, consentGranted: consentGranted)
    }

    // MARK: - The consent gate

    @Test("without consent there is no call to make, whatever else is true")
    func consentComesFirst() {
        #expect(route(consentGranted: false) == .consentNeeded)
        #expect(route(isPro: true, consentGranted: false) == .consentNeeded)
        // Ahead of the quota gate: nobody spends a tidy they haven't agreed to,
        // and "you're out" is the wrong thing to tell someone who never started.
        #expect(route(cloudRemaining: 0, consentGranted: false) == .consentNeeded)
        #expect(route(cloudRemaining: nil, consentGranted: false) == .consentNeeded)
    }

    // MARK: - The quota gate

    @Test("a free user with tidies left gets one")
    func freeWithQuotaTidies() {
        #expect(route() == .cloud)
        #expect(route(cloudRemaining: 1) == .cloud)
    }

    @Test("a spent quota is a wall, not a slower route")
    func exhaustedQuotaBlocks() {
        #expect(route(cloudRemaining: 0) == .blocked(.cloudQuotaExhausted))
        // A count below zero is a server that counted past the limit; it means
        // the same thing.
        #expect(route(cloudRemaining: -1) == .blocked(.cloudQuotaExhausted))
    }

    @Test("Pro is never walled, whatever the count says")
    func proIsNeverBlocked() {
        #expect(route(isPro: true, cloudRemaining: 0) == .cloud)
        #expect(route(isPro: true, cloudRemaining: nil) == .cloud)
    }

    @Test("an unknown count is treated optimistically — the server owns the wall")
    func unknownQuotaTries() {
        #expect(route(cloudRemaining: nil) == .cloud)
    }

    // MARK: - Where the count comes from

    @Test("last month's spent quota doesn't block this month")
    func rolledOverQuotaIsFresh() throws {
        let suiteName = "RoutingPolicyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = EntitlementStore(defaults: defaults)
        store.recordQuota(used: 5, limit: 5, month: "2026-07", isPro: false)
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-07T12:00:00Z"))

        #expect(store.cloudRemaining(now: now) == nil)
        #expect(route(cloudRemaining: store.cloudRemaining(now: now)) == .cloud)
    }
}
