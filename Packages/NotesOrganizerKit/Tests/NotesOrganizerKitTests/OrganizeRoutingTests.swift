import Foundation
import Testing
@testable import NotesOrganizerKit

/// `RoutingPolicy` is tested against the plan's table already. What's left
/// here is everything the table doesn't cover: the kill switch, reading the
/// plan out of a store rather than being handed it, and the one decision the
/// preview screen makes — whether to offer a premium tidy at all.
@Suite("OrganizeRouting")
struct OrganizeRoutingTests {
    private let note = OrganizedNote(title: "Note", sections: [], actionItems: [])

    /// A store on a throwaway suite, so nothing here touches the App Group or
    /// another test's state.
    private func makeStore() throws -> (EntitlementStore, () -> Void) {
        let suiteName = "OrganizeRoutingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (EntitlementStore(defaults: defaults), { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func makeRouting(store: EntitlementStore, cloudEnabled: Bool = true) -> OrganizeRouting {
        OrganizeRouting(
            store: store,
            cloudEnabled: cloudEnabled,
            cloud: MockOrganizer(result: note),
            onDevice: MockOrganizer(result: note)
        )
    }

    // MARK: - The kill switch

    @Test("with the cloud switched off everything runs on-device")
    func killSwitchRoutesOnDevice() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.recordQuota(used: 0, limit: 5, month: EntitlementStore.monthKey(for: Date()), isPro: false)
        store.setCloudConsentGranted(true)

        let routing = makeRouting(store: store, cloudEnabled: false)
        #expect(routing.route(preference: .automatic, onDeviceFailure: nil) == .onDevice)
        // Even an explicit premium tidy, which nothing can offer while the
        // switch is off.
        #expect(routing.route(preference: .forceCloud, onDeviceFailure: nil) == .onDevice)
    }

    @Test("with the cloud switched off an unusable model is the whole story")
    func killSwitchSurfacesOnDeviceFailure() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }

        let routing = makeRouting(store: store, cloudEnabled: false)
        #expect(routing.route(preference: .automatic, onDeviceFailure: .deviceNotEligible)
            == .blocked(.deviceNotEligible))
    }

    // MARK: - Reading the plan

    @Test("a Pro subscription in the store routes to the cloud")
    func proRoutesToCloud() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.recordIsPro(true)
        store.setCloudConsentGranted(true)

        let routing = makeRouting(store: store)
        #expect(routing.route(preference: .automatic, onDeviceFailure: nil) == .cloud(fallbackOnDevice: true))
    }

    @Test("consent that was never given stops a run before it starts")
    func missingConsentAsksFirst() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.recordIsPro(true)

        let routing = makeRouting(store: store)
        #expect(routing.route(preference: .automatic, onDeviceFailure: nil) == .consentNeeded)

        routing.setCloudConsentGranted(true)
        #expect(routing.route(preference: .automatic, onDeviceFailure: nil) == .cloud(fallbackOnDevice: true))
    }

    // MARK: - The premium tidy offer

    @Test("a free user with quota left is offered a premium tidy, counted")
    func freeUserIsOffered() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.recordQuota(used: 2, limit: 5, month: EntitlementStore.monthKey(for: Date()), isPro: false)
        store.setCloudConsentGranted(true)

        let offer = makeRouting(store: store).premiumTidyOffer()
        #expect(offer == PremiumTidyOffer(remaining: 3))
        #expect(offer?.title == "Premium tidy — 3 left this month")
    }

    @Test("an unknown count is offered without a number rather than a guess")
    func unknownCountDropsTheNumber() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.setCloudConsentGranted(true)

        let offer = makeRouting(store: store).premiumTidyOffer()
        #expect(offer == PremiumTidyOffer(remaining: nil))
        #expect(offer?.title == "Premium tidy")
    }

    @Test("consent that hasn't been asked for yet still gets the offer — tapping is how we ask")
    func offerAppearsBeforeConsent() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }

        #expect(makeRouting(store: store).premiumTidyOffer() != nil)
    }

    @Test("Pro is never offered a premium tidy, or a count of them")
    func proIsNotOffered() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        // The server reports a huge limit for Pro; nothing may render it.
        store.recordQuota(used: 3, limit: 1_000_000, month: EntitlementStore.monthKey(for: Date()), isPro: true)
        store.setCloudConsentGranted(true)

        #expect(makeRouting(store: store).premiumTidyOffer() == nil)
        #expect(store.cloudRemaining() == nil)
    }

    @Test("a spent quota belongs on the screen that tried, not on a preview that worked")
    func exhaustedQuotaIsNotOffered() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.recordQuota(used: 5, limit: 5, month: EntitlementStore.monthKey(for: Date()), isPro: false)
        store.setCloudConsentGranted(true)

        #expect(makeRouting(store: store).premiumTidyOffer() == nil)
    }

    @Test("nothing is offered while the cloud is switched off")
    func killSwitchHidesTheOffer() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.setCloudConsentGranted(true)

        #expect(makeRouting(store: store, cloudEnabled: false).premiumTidyOffer() == nil)
    }

    // MARK: - Building the organizer

    @Test("the organizer it builds runs the route it was given")
    func organizerFollowsTheRoute() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }

        let cloud = MockOrganizer(result: OrganizedNote(title: "Cloud", sections: [], actionItems: []))
        let onDevice = MockOrganizer(result: OrganizedNote(title: "On-device", sections: [], actionItems: []))
        let routing = OrganizeRouting(store: store, cloudEnabled: true, cloud: cloud, onDevice: onDevice)

        let organizer = routing.organizer(
            for: .onDevice,
            source: .app,
            log: DiagnosticsLog(storage: InMemoryDiagnosticsStorage())
        )
        let produced = try await organizer.organize("a transcript worth organizing")
        #expect(produced.title == "On-device")
        #expect(await cloud.receivedTranscripts.isEmpty)
    }
}
