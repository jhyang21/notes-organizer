import Foundation
import NotesOrganizerKit
import Testing
@testable import NotesOrganizer

/// An App Store that does what the test tells it to. The stream is built up
/// front, so a test can send an update without racing the controller's
/// subscription — an `AsyncStream` holds what it was given until someone
/// iterates it.
@MainActor
private final class MockPurchaseService: PurchaseService {
    var isConfigured = false
    var restoreResult: Result<Bool, any Error> = .success(false)

    private(set) var configuredAppUserID: String?

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

    /// One word from the store about the customer, as the SDK's stream would
    /// deliver it.
    func send(isPro: Bool) {
        continuation.yield(isPro)
    }
}

/// A restore that failed for a reason only a log should ever repeat.
private struct StoreUnreachable: LocalizedError {
    var errorDescription: String? { "The App Store returned 503 (service unavailable)" }
}

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
}
