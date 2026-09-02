import Foundation
import Testing
@testable import NotesOrganizerKit

/// `RoutingPolicy` is tested against its own table already. What's left here is
/// the facade: reading the plan out of a store rather than being handed it, the
/// session-scoped consent fallback, and handing back the organizer that runs.
@Suite("OrganizeRouting")
struct OrganizeRoutingTests {
    private let note = OrganizedNote(title: "Note")

    /// A store on a throwaway suite, so nothing here touches the App Group or
    /// another test's state.
    private func makeStore() throws -> (EntitlementStore, () -> Void) {
        let suiteName = "OrganizeRoutingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (EntitlementStore(defaults: defaults), { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func makeRouting(store: EntitlementStore) -> OrganizeRouting {
        OrganizeRouting(store: store, cloud: MockOrganizer(result: note))
    }

    // MARK: - Reading the plan

    @Test("consent that was never given stops a run before it starts")
    func missingConsentAsksFirst() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }

        let routing = makeRouting(store: store)
        #expect(routing.route() == .consentNeeded)

        routing.setCloudConsentGranted(true)
        #expect(routing.route() == .cloud)
    }

    @Test("a spent quota in the store is a wall")
    func exhaustedQuotaBlocks() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.setCloudConsentGranted(true)
        store.recordQuota(used: 5, limit: 5, month: EntitlementStore.monthKey(for: Date()), isPro: false)

        #expect(makeRouting(store: store).route() == .blocked(.cloudQuotaExhausted))
    }

    @Test("a Pro subscription in the store passes the same spent quota")
    func proIsNotBlocked() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.setCloudConsentGranted(true)
        store.recordQuota(used: 9, limit: 5, month: EntitlementStore.monthKey(for: Date()), isPro: true)

        let routing = makeRouting(store: store)
        #expect(routing.isPro)
        #expect(routing.route() == .cloud)
    }

    @Test("a device that couldn't keep the answer is asked once, not every run")
    func sessionConsentStandsIn() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }

        let routing = makeRouting(store: store)
        #expect(routing.route() == .consentNeeded)
        #expect(routing.route(consentGrantedThisSession: true) == .cloud)
    }

    @Test("consent granted this session still doesn't buy a tidy the month is out of")
    func sessionConsentDoesNotSkipTheQuota() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        store.recordQuota(used: 5, limit: 5, month: EntitlementStore.monthKey(for: Date()), isPro: false)

        #expect(makeRouting(store: store).route(consentGrantedThisSession: true)
            == .blocked(.cloudQuotaExhausted))
    }

    // MARK: - Building the organizer

    @Test("the organizer it hands back is the one it was built with")
    func organizerIsTheCloudOne() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }

        let cloud = MockOrganizer(result: OrganizedNote(title: "Cloud"))
        let routing = OrganizeRouting(store: store, cloud: cloud)

        let produced = try await routing.organizer().organize("a transcript worth organizing")
        #expect(produced.title == "Cloud")
        #expect(await cloud.receivedTranscripts == ["a transcript worth organizing"])
    }

    @Test("the voice path runs on the same organizer as the text path")
    func voiceOrganizerIsTheSameOne() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }

        let cloud = MockOrganizer(result: OrganizedNote(title: "Cloud"))
        let routing = OrganizeRouting(store: store, cloud: cloud)
        let recording = URL(fileURLWithPath: "/tmp/capture-test.m4a")

        let produced = try await routing.voiceOrganizer()
            .organize(audioAt: recording, durationSeconds: 42, locale: Locale(identifier: "en_US"))

        #expect(produced.title == "Cloud")
        #expect(await cloud.receivedRecordings == [recording])
    }
}
