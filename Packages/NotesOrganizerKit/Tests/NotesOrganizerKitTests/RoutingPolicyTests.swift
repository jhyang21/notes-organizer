import Foundation
import Testing
@testable import NotesOrganizerKit

/// One test per row of the plan's routing table, plus the two cases the table
/// doesn't spell out: an unknown quota and a month that has rolled over.
@Suite("RoutingPolicy")
struct RoutingPolicyTests {
    private func route(
        isPro: Bool = false,
        cloudRemaining: Int? = 5,
        onDeviceFailure: OrganizeFailure? = nil,
        consentGranted: Bool = true,
        preference: RoutingPolicy.Preference = .automatic
    ) -> RoutingPolicy.Route {
        RoutingPolicy.route(
            isPro: isPro,
            cloudRemaining: cloudRemaining,
            onDeviceFailure: onDeviceFailure,
            consentGranted: consentGranted,
            preference: preference
        )
    }

    // MARK: - The table

    @Test("an explicit premium tidy goes to the cloud and never quietly downgrades")
    func forceCloudNeverFallsBack() {
        #expect(route(preference: .forceCloud) == .cloud(fallbackOnDevice: false))
        // Even where an on-device tidy is available to fall back to.
        #expect(route(isPro: true, preference: .forceCloud) == .cloud(fallbackOnDevice: false))
    }

    @Test("Pro gets the cloud, with on-device as the safety net when it exists")
    func proPrefersCloudWithFallback() {
        #expect(route(isPro: true, cloudRemaining: nil) == .cloud(fallbackOnDevice: true))
    }

    @Test("Pro on hardware with no on-device model has nothing to fall back to")
    func proWithoutOnDeviceSurfacesErrors() {
        #expect(route(isPro: true, cloudRemaining: nil, onDeviceFailure: .deviceNotEligible) == .cloud(fallbackOnDevice: false))
    }

    @Test("a free user with an on-device model stays on it, unlimited")
    func freeUsesOnDevice() {
        #expect(route() == .onDevice)
        // Quota and consent are beside the point when nothing leaves the phone.
        #expect(route(cloudRemaining: 0, consentGranted: false) == .onDevice)
    }

    @Test("a free user with no on-device model spends quota, with no fallback")
    func freeWithoutOnDeviceUsesCloud() {
        #expect(route(cloudRemaining: 3, onDeviceFailure: .deviceNotEligible) == .cloud(fallbackOnDevice: false))
    }

    @Test("a spent quota is a wall, not a slower route")
    func exhaustedQuotaBlocks() {
        #expect(route(cloudRemaining: 0, onDeviceFailure: .deviceNotEligible) == .blocked(.cloudQuotaExhausted))
    }

    @Test("without consent there is no cloud call to make")
    func withoutConsentAsksFirst() {
        #expect(route(onDeviceFailure: .deviceNotEligible, consentGranted: false) == .consentNeeded)
        // Consent comes before quota: nobody spends a tidy they haven't agreed to.
        #expect(route(cloudRemaining: 0, onDeviceFailure: .deviceNotEligible, consentGranted: false) == .consentNeeded)
        #expect(route(consentGranted: false, preference: .forceCloud) == .consentNeeded)
    }

    // MARK: - What the table leaves open

    @Test("an unknown quota is treated optimistically — the server owns the wall")
    func unknownQuotaTriesTheCloud() {
        #expect(route(cloudRemaining: nil, onDeviceFailure: .deviceNotEligible) == .cloud(fallbackOnDevice: false))
    }

    @Test("last month's spent quota doesn't block this month")
    func rolledOverQuotaIsFresh() throws {
        let suiteName = "RoutingPolicyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = EntitlementStore(defaults: defaults)
        store.recordQuota(used: 5, limit: 5, month: "2026-07", isPro: false)
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-07T12:00:00Z"))

        #expect(store.cloudRemaining(now: now) == nil)
        #expect(route(cloudRemaining: store.cloudRemaining(now: now), onDeviceFailure: .deviceNotEligible)
            == .cloud(fallbackOnDevice: false))
    }

    @Test("an on-device model that's merely busy still counts as unavailable")
    func anyOnDeviceFailureRoutesToCloud() {
        let busy = OrganizeFailure.modelNotReady(reason: "busy")
        #expect(route(onDeviceFailure: busy) == .cloud(fallbackOnDevice: false))
        #expect(route(isPro: true, onDeviceFailure: busy) == .cloud(fallbackOnDevice: false))
    }
}
