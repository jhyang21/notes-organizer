import Foundation
import Testing
@testable import NotesOrganizerKit

@Suite("EntitlementStore")
struct EntitlementStoreTests {
    /// A throwaway suite per test, removed afterwards, so nothing leaks into
    /// the next test or the machine running it.
    private func withStore(_ body: (EntitlementStore) throws -> Void) throws {
        let suiteName = "EntitlementStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(EntitlementStore(defaults: defaults))
    }

    private func date(_ iso: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        return try #require(formatter.date(from: iso))
    }

    // MARK: - Identity

    @Test("the app user ID is created once and then read back")
    func appUserIDIsStable() throws {
        try withStore { store in
            let first = store.appUserID()
            #expect(first.hasPrefix("tidy:"))
            #expect(store.appUserID() == first)
        }
    }

    @Test("both processes over one suite see the same ID")
    func appUserIDIsSharedAcrossInstances() throws {
        let suiteName = "EntitlementStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let app = EntitlementStore(defaults: defaults)
        let extensionSide = EntitlementStore(defaults: defaults)

        #expect(extensionSide.appUserID() == app.appUserID())
    }

    // MARK: - Plan

    @Test("plan state round-trips")
    func planRoundTrips() throws {
        try withStore { store in
            #expect(store.planState() == nil)

            store.record(PlanState(isPro: true, cloudUsed: 3, cloudLimit: 5, monthKey: "2026-08"))

            let state = try #require(store.planState())
            #expect(state.isPro)
            #expect(state.cloudUsed == 3)
            #expect(state.cloudLimit == 5)
            #expect(state.monthKey == "2026-08")
            #expect(store.isPro())
        }
    }

    @Test("recording a quota stores exactly what the server said")
    func quotaIsStoredVerbatim() throws {
        try withStore { store in
            store.recordQuota(used: 4, limit: 5, month: "2026-08", isPro: false)
            store.recordQuota(used: 2, limit: 5, month: "2026-08", isPro: false)

            // Second write wins outright — no local accumulation.
            let state = try #require(store.planState())
            #expect(state.cloudUsed == 2)
        }
    }

    @Test("mirroring the subscription keeps the quota counts")
    func recordingProKeepsQuota() throws {
        try withStore { store in
            store.recordQuota(used: 4, limit: 5, month: "2026-08", isPro: false)
            store.recordIsPro(true)

            let state = try #require(store.planState())
            #expect(state.isPro)
            #expect(state.cloudUsed == 4)
        }
    }

    // MARK: - Remaining

    @Test("remaining counts down from the limit the server reported")
    func remainingSubtractsUsed() throws {
        let now = try date("2026-08-07T12:00:00Z")
        try withStore { store in
            store.recordQuota(used: 2, limit: 5, month: "2026-08", isPro: false)
            #expect(store.cloudRemaining(now: now) == 3)
        }
    }

    @Test("a spent month reads as zero, not a negative number")
    func remainingFloorsAtZero() throws {
        let now = try date("2026-08-07T12:00:00Z")
        try withStore { store in
            store.recordQuota(used: 7, limit: 5, month: "2026-08", isPro: false)
            #expect(store.cloudRemaining(now: now) == 0)
        }
    }

    @Test("counts from last month say nothing about this one")
    func monthRolloverClearsRemaining() throws {
        let now = try date("2026-08-07T12:00:00Z")
        try withStore { store in
            store.recordQuota(used: 5, limit: 5, month: "2026-07", isPro: false)
            #expect(store.cloudRemaining(now: now) == nil)
        }
    }

    @Test("nothing stored and unlimited both read as unknown")
    func remainingIsNilWithoutAnswerableState() throws {
        let now = try date("2026-08-07T12:00:00Z")
        try withStore { store in
            #expect(store.cloudRemaining(now: now) == nil)

            store.record(PlanState(isPro: true, cloudUsed: 9, cloudLimit: 5, monthKey: "2026-08"))
            #expect(store.cloudRemaining(now: now) == nil)
        }
    }

    @Test("the month key is UTC, so a time zone can't move it")
    func monthKeyIsUTC() throws {
        let justAfterMidnight = try date("2026-08-01T00:30:00Z")
        let justBefore = try date("2026-07-31T23:30:00Z")
        let midJanuary = try date("2026-01-15T12:00:00Z")

        #expect(EntitlementStore.monthKey(for: justAfterMidnight) == "2026-08")
        #expect(EntitlementStore.monthKey(for: justBefore) == "2026-07")
        #expect(EntitlementStore.monthKey(for: midJanuary) == "2026-01")
    }

    // MARK: - Consent

    @Test("consent starts off and persists once granted")
    func consentPersists() throws {
        try withStore { store in
            #expect(store.cloudConsentGranted == false)
            store.setCloudConsentGranted(true)
            #expect(store.cloudConsentGranted)
            store.setCloudConsentGranted(false)
            #expect(store.cloudConsentGranted == false)
        }
    }

    // MARK: - No shared storage

    @Test("a build without the App Group degrades to no-ops")
    func missingSuiteIsSafe() {
        let store = EntitlementStore(defaults: nil)

        store.record(PlanState(isPro: true, cloudUsed: 1, cloudLimit: 5, monthKey: "2026-08"))
        store.setCloudConsentGranted(true)

        #expect(store.planState() == nil)
        #expect(store.isPro() == false)
        #expect(store.cloudRemaining() == nil)
        #expect(store.cloudConsentGranted == false)
        // Still hands back a well-formed ID, so a call can be made — it just
        // won't be the same one twice.
        #expect(store.appUserID().hasPrefix("tidy:"))
    }
}
