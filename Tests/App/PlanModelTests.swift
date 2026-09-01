import Foundation
import NotesOrganizerKit
import Testing
@testable import NotesOrganizer

@MainActor
@Suite("PlanModel")
struct PlanModelTests {
    @Test("a fresh install says nothing about the count")
    func freshInstall() throws {
        let defaults = try EphemeralDefaults()
        let plan = PlanModel(store: EntitlementStore(defaults: defaults.defaults))

        #expect(plan.isPro == false)
        #expect(plan.remaining == nil)
    }

    @Test("a free plan reports what the server last counted")
    func freePlanCount() throws {
        let defaults = try EphemeralDefaults()
        let plan = PlanModel(store: makeStore(defaults, remaining: 3))

        #expect(plan.isPro == false)
        #expect(plan.remaining == 3)
    }

    @Test("Pro has no count to report")
    func proHasNoCount() throws {
        let defaults = try EphemeralDefaults()
        let store = makeStore(defaults, remaining: 3)
        store.recordIsPro(true)

        let plan = PlanModel(store: store)

        #expect(plan.isPro)
        #expect(plan.remaining == nil)
    }

    @Test("counts from a month that has since rolled over are not reported")
    func staleMonth() throws {
        let defaults = try EphemeralDefaults()
        let store = EntitlementStore(defaults: defaults.defaults)
        store.recordQuota(used: 4, limit: PlanState.freeMonthlyLimit, month: "2000-01", isPro: false)

        let plan = PlanModel(store: store)

        #expect(plan.remaining == nil)
    }

    /// The share extension spends tidies in a process of its own, and nothing
    /// tells this one. Coming back and asking again is the whole mechanism.
    @Test("refresh picks up a tidy spent by the other process")
    func refreshSeesAnotherProcess() throws {
        let defaults = try EphemeralDefaults()
        let plan = PlanModel(store: makeStore(defaults, remaining: 5))

        let extensionStore = EntitlementStore(defaults: defaults.defaults)
        extensionStore.recordQuota(
            used: 4,
            limit: PlanState.freeMonthlyLimit,
            month: currentMonthKey(),
            isPro: false
        )

        #expect(plan.remaining == 5, "the snapshot is only as old as the last refresh")

        plan.refresh()

        #expect(plan.remaining == 1)
    }

    @Test("refresh picks up a subscription bought since the snapshot")
    func refreshSeesPurchase() throws {
        let defaults = try EphemeralDefaults()
        let store = makeStore(defaults, remaining: 2)
        let plan = PlanModel(store: store)

        store.recordIsPro(true)
        plan.refresh()

        #expect(plan.isPro)
        #expect(plan.remaining == nil)
    }
}
