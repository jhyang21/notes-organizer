import Foundation
import NotesOrganizerKit
import Testing
@testable import NotesOrganizer

@MainActor
@Suite("PurchasesController")
struct PurchasesControllerTests {
    /// One store behind the plan and the controller, the way the app wires
    /// them: a write through either has to show up in both.
    private struct Rig {
        let store: EntitlementStore
        let plan: PlanModel
        let service: MockPurchaseService
        let log: DiagnosticsLog
        let controller: PurchasesController
    }

    private func makeRig(_ defaults: EphemeralDefaults) -> Rig {
        let store = EntitlementStore(defaults: defaults.defaults)
        let plan = PlanModel(store: store)
        let service = MockPurchaseService()
        let log = makeLog()

        return Rig(
            store: store,
            plan: plan,
            service: service,
            log: log,
            controller: PurchasesController(plan: plan, service: service, store: store, log: log)
        )
    }

    // MARK: - Configuring

    @Test("the SDK is started with the same ID the server counts against")
    func configureUsesTheAppUserID() throws {
        let defaults = try EphemeralDefaults()
        let rig = makeRig(defaults)

        rig.controller.configure()

        #expect(rig.service.configuredAppUserID == rig.store.appUserID())
    }

    @Test("an SDK already running is left alone")
    func configureRunsOnce() throws {
        let defaults = try EphemeralDefaults()
        let rig = makeRig(defaults)
        rig.service.isConfigured = true

        rig.controller.configure()

        #expect(rig.service.configuredAppUserID == nil)
    }

    // MARK: - Following the customer

    @Test("a subscription the SDK reports reaches the App Group and the plan")
    func streamRecordsPro() async throws {
        let defaults = try EphemeralDefaults()
        let rig = makeRig(defaults)
        rig.controller.configure()

        rig.service.send(isPro: true)

        try await waitUntil("the entitlement to be recorded") { rig.store.isPro() }
        #expect(rig.plan.isPro)
    }

    @Test("a subscription that has lapsed is recorded too")
    func streamRecordsLapse() async throws {
        let defaults = try EphemeralDefaults()
        let rig = makeRig(defaults)
        rig.store.recordIsPro(true)
        rig.plan.refresh()
        rig.controller.configure()

        rig.service.send(isPro: false)

        try await waitUntil("the lapse to be recorded") { !rig.store.isPro() }
        #expect(rig.plan.isPro == false)
    }

    // MARK: - Restoring

    @Test("a restore that finds a subscription turns Pro on everywhere")
    func restoreFindsPro() async throws {
        let defaults = try EphemeralDefaults()
        let rig = makeRig(defaults)
        rig.service.restoreResult = .success(true)

        let outcome = await rig.controller.restore()

        #expect(outcome == .restored)
        #expect(rig.store.isPro())
        #expect(rig.plan.isPro)
        #expect(rig.controller.isRestoring == false)
    }

    @Test("a restore that finds nothing says so rather than claiming Pro")
    func restoreFindsNothing() async throws {
        let defaults = try EphemeralDefaults()
        let rig = makeRig(defaults)
        rig.service.restoreResult = .success(false)

        let outcome = await rig.controller.restore()

        #expect(outcome == .nothingToRestore)
        #expect(rig.store.isPro() == false)
    }

    /// The user gets one fixed sentence; the SDK's own words go where only
    /// someone debugging will read them.
    @Test("a failed restore keeps the real error out of the alert")
    func restoreFailure() async throws {
        let defaults = try EphemeralDefaults()
        let rig = makeRig(defaults)
        rig.service.restoreResult = .failure(StoreUnreachable())

        let outcome = await rig.controller.restore()

        #expect(outcome == .failed)
        #expect(outcome.message == "Check your connection and try again.")
        #expect(rig.log.events().contains { $0.message.contains("503") })
        #expect(rig.store.isPro() == false)
        #expect(rig.controller.isRestoring == false)
    }

    // MARK: - Buying

    @Test("a purchase the store completed turns Pro on everywhere")
    func purchaseRecordsPro() async throws {
        let defaults = try EphemeralDefaults()
        let rig = makeRig(defaults)
        rig.service.purchaseResult = .success(.purchased(isPro: true))

        let outcome = await rig.controller.purchase(planID: annualPlanID)

        #expect(outcome == .purchased(isPro: true))
        #expect(rig.service.purchasedPlanIDs == [annualPlanID])
        #expect(rig.store.isPro())
        #expect(rig.plan.isPro)
        #expect(rig.controller.isPurchasing == false)
    }

    /// A closed store sheet is the user changing their mind, which is neither
    /// a failure to report nor an event to keep.
    @Test("a cancelled purchase changes nothing and logs nothing")
    func purchaseCancelled() async throws {
        let defaults = try EphemeralDefaults()
        let rig = makeRig(defaults)
        rig.service.purchaseResult = .success(.cancelled)

        let outcome = await rig.controller.purchase(planID: annualPlanID)

        #expect(outcome == .cancelled)
        #expect(rig.store.isPro() == false)
        #expect(rig.log.events().isEmpty)
        #expect(rig.controller.isPurchasing == false)
    }

    @Test("a failed purchase keeps the real error out of the alert")
    func purchaseFailure() async throws {
        let defaults = try EphemeralDefaults()
        let rig = makeRig(defaults)
        rig.service.purchaseResult = .failure(StoreUnreachable())

        let outcome = await rig.controller.purchase(planID: annualPlanID)

        #expect(outcome == .failed)
        #expect(outcome.title == "Couldn't complete the purchase")
        #expect(rig.log.events().contains { $0.message.contains("503") })
        #expect(rig.store.isPro() == false)
        #expect(rig.controller.isPurchasing == false)
    }

    @Test("a store the app couldn't reach reads the same whichever button was pressed")
    func purchaseFailureMatchesRestore() {
        #expect(
            PurchasesController.PurchaseOutcome.failed.message
                == PurchasesController.RestoreOutcome.failed.message
        )
    }
}
