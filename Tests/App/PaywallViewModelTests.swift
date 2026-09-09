import Foundation
import NotesOrganizerKit
import Testing
@testable import NotesOrganizer

/// What the paywall says, and what it does with the answer. Everything here
/// is a rule that could quietly become untrue on a shipped build — which plan
/// is preselected, whether the button promises a trial the account can't
/// have, what a cancelled purchase leaves behind — and none of it needs a
/// device or an Apple Account to check.
@MainActor
@Suite("PaywallViewModel")
struct PaywallViewModelTests {
    /// The paywall wired the way the app wires it: one store behind the plan,
    /// the controller and the view model, so a purchase made here has to show
    /// up in all three.
    private struct Rig {
        let store: EntitlementStore
        let plan: PlanModel
        let service: MockPurchaseService
        let log: DiagnosticsLog
        let viewModel: PaywallViewModel
    }

    private func makeRig(
        _ defaults: EphemeralDefaults,
        offer: PaywallOffer? = makeOffer(),
        eligiblePlanIDs: Set<String> = [],
        isOnline: Bool = true,
        origin: PaywallViewModel.Origin = .general
    ) -> Rig {
        let store = EntitlementStore(defaults: defaults.defaults)
        let plan = PlanModel(store: store)
        let log = makeLog()

        let service = MockPurchaseService()
        service.offerResult = .success(offer)
        service.eligiblePlanIDs = eligiblePlanIDs

        let connectivity = MockConnectivity()
        connectivity.isOnlineValue = isOnline

        let purchases = PurchasesController(plan: plan, service: service, store: store, log: log)

        return Rig(
            store: store,
            plan: plan,
            service: service,
            log: log,
            viewModel: PaywallViewModel(
                purchases: purchases,
                origin: origin,
                connectivity: connectivity
            )
        )
    }

    /// Both plans, both still eligible for the trial — the state a fresh
    /// install lands in, and the one most tests start from.
    private func makeReadyRig(_ defaults: EphemeralDefaults) async -> Rig {
        let rig = makeRig(defaults, eligiblePlanIDs: [annualPlanID, monthlyPlanID])
        await rig.viewModel.load()
        return rig
    }

    // MARK: - Loading

    @Test("a phone with no connection is told so rather than left on a spinner")
    func offlineLoad() async throws {
        let defaults = try EphemeralDefaults()
        let rig = makeRig(defaults, isOnline: false)

        await rig.viewModel.load()

        #expect(rig.viewModel.phase == .offline)
    }

    @Test("a store that refuses to answer is a dead end, not an empty screen")
    func offerThrows() async throws {
        let defaults = try EphemeralDefaults()
        let rig = makeRig(defaults)
        rig.service.offerResult = .failure(StoreUnreachable())

        await rig.viewModel.load()

        #expect(rig.viewModel.phase == .unavailable)
    }

    @Test("a store with nothing to sell is the same dead end")
    func offerIsNil() async throws {
        let defaults = try EphemeralDefaults()
        let rig = makeRig(defaults, offer: nil)

        await rig.viewModel.load()

        #expect(rig.viewModel.phase == .unavailable)
    }

    @Test("the yearly plan is the one already selected")
    func annualIsPreselected() async throws {
        let defaults = try EphemeralDefaults()
        let rig = await makeReadyRig(defaults)

        #expect(rig.viewModel.phase == .ready(makeOffer()))
        #expect(rig.viewModel.selectedPlanID == annualPlanID)
    }

    @Test("an offering with one plan in it selects that one")
    func singlePlanIsSelected() async throws {
        let defaults = try EphemeralDefaults()
        let rig = makeRig(defaults, offer: makeOffer(includesAnnual: false))

        await rig.viewModel.load()

        #expect(rig.viewModel.selectedPlanID == monthlyPlanID)
    }

    // MARK: - What the button says

    @Test("an account that can still start a trial is offered the trial")
    func callToActionWithATrial() async throws {
        let defaults = try EphemeralDefaults()
        let rig = await makeReadyRig(defaults)

        #expect(rig.viewModel.callToAction == "Start 7-Day Free Trial")
        #expect(
            rig.viewModel.billingLine
                == "7-day free trial, then $39.99/year. Renews automatically. Cancel anytime in Settings."
        )
    }

    /// The button names the price rather than saying "Subscribe", because by
    /// then the user has tapped a card and shouldn't have to remember which.
    @Test("an account that has used its trial is offered the subscription")
    func callToActionWithoutATrial() async throws {
        let defaults = try EphemeralDefaults()
        let rig = makeRig(defaults, eligiblePlanIDs: [])

        await rig.viewModel.load()

        #expect(rig.viewModel.callToAction == "Subscribe for $39.99/year")
        #expect(
            rig.viewModel.billingLine
                == "$39.99/year, renews automatically. Cancel anytime in Settings."
        )
    }

    @Test("the button and the small print follow the selected card")
    func callToActionFollowsTheSelection() async throws {
        let defaults = try EphemeralDefaults()
        let rig = makeRig(defaults, eligiblePlanIDs: [])

        await rig.viewModel.load()
        rig.viewModel.select(monthlyPlanID)

        #expect(rig.viewModel.callToAction == "Subscribe for $4.99/month")
        #expect(
            rig.viewModel.billingLine
                == "$4.99/month, renews automatically. Cancel anytime in Settings."
        )
    }

    /// Eligibility and an actual introductory offer are two different things,
    /// and promising a trial the product doesn't carry is the worse mistake.
    @Test("a plan with no trial on it is never sold as one")
    func planWithoutATrial() async throws {
        let defaults = try EphemeralDefaults()
        let rig = makeRig(
            defaults,
            offer: makeOffer(trialDays: nil),
            eligiblePlanIDs: [annualPlanID, monthlyPlanID]
        )

        await rig.viewModel.load()

        #expect(rig.viewModel.isTrialEligible == false)
        #expect(rig.viewModel.callToAction == "Subscribe for $39.99/year")
    }

    // MARK: - The rest of the copy

    @Test("someone sent here by a spent month is told what happens to their tidy")
    func quotaWallSupportingLine() async throws {
        let defaults = try EphemeralDefaults()
        let general = makeRig(defaults, origin: .general)
        let quotaWall = makeRig(defaults, origin: .quotaWall)

        #expect(
            general.viewModel.supportingLine
                == "Every ramble and every messy note comes back organized, as often as you need."
        )
        #expect(
            quotaWall.viewModel.supportingLine
                == "You've used this month's free tidies. Go Pro and the note you were tidying picks up where it left off."
        )
    }

    /// VoiceOver reads one sentence per card. The percent sign is left to the
    /// device's own number formatting.
    @Test("a card is read out as the whole offer, not as four labels")
    func accessibilityLabels() async throws {
        let defaults = try EphemeralDefaults()
        let rig = await makeReadyRig(defaults)
        let offer = try #require(rig.viewModel.offer)

        let annual = try #require(offer.plans.first { $0.id == annualPlanID })
        let annualLabel = rig.viewModel.accessibilityLabel(for: annual)
        #expect(annualLabel.hasPrefix("Yearly, $39.99 per year, $3.33 per month, Save "))
        #expect(annualLabel.contains("33"))
        #expect(annualLabel.hasSuffix(", Best value"))

        let monthly = try #require(offer.plans.first { $0.id == monthlyPlanID })
        #expect(rig.viewModel.accessibilityLabel(for: monthly) == "Monthly, $4.99 per month")
    }

    // MARK: - Buying

    @Test("a completed purchase unlocks Pro and closes the sheet")
    func purchaseSucceeds() async throws {
        let defaults = try EphemeralDefaults()
        let rig = await makeReadyRig(defaults)
        rig.service.purchaseResult = .success(.purchased(isPro: true))

        await rig.viewModel.purchase()

        #expect(rig.service.purchasedPlanIDs == [annualPlanID])
        #expect(rig.store.isPro())
        #expect(rig.plan.isPro)
        #expect(rig.viewModel.didUnlockPro)
        #expect(rig.viewModel.shouldDismiss)
        #expect(rig.viewModel.isShowingAlert == false)
    }

    /// Closing the store's own sheet is not something to be told about.
    @Test("a cancelled purchase says nothing and leaves the paywall up")
    func purchaseCancelled() async throws {
        let defaults = try EphemeralDefaults()
        let rig = await makeReadyRig(defaults)
        rig.service.purchaseResult = .success(.cancelled)

        await rig.viewModel.purchase()

        #expect(rig.viewModel.isShowingAlert == false)
        #expect(rig.viewModel.alert == nil)
        #expect(rig.viewModel.shouldDismiss == false)
        #expect(rig.viewModel.didUnlockPro == false)
        #expect(rig.store.isPro() == false)
        #expect(rig.log.events().isEmpty)
    }

    @Test("a failed purchase gets fixed copy, and the real error goes to the log")
    func purchaseFails() async throws {
        let defaults = try EphemeralDefaults()
        let rig = await makeReadyRig(defaults)
        rig.service.purchaseResult = .failure(StoreUnreachable())

        await rig.viewModel.purchase()

        #expect(rig.viewModel.isShowingAlert)
        #expect(rig.viewModel.alert?.title == "Couldn't complete the purchase")
        #expect(rig.viewModel.alert?.message == "Check your connection and try again.")
        #expect(rig.viewModel.shouldDismiss == false)
        #expect(rig.log.events().contains { $0.message.contains("503") })
    }

    // MARK: - Restoring

    @Test("a restore that finds a subscription closes the sheet")
    func restoreFindsPro() async throws {
        let defaults = try EphemeralDefaults()
        let rig = await makeReadyRig(defaults)
        rig.service.restoreResult = .success(true)

        await rig.viewModel.restore()

        #expect(rig.viewModel.didUnlockPro)
        #expect(rig.viewModel.shouldDismiss)
        #expect(rig.store.isPro())
    }

    /// The user came here to subscribe. Closing on them would read as though
    /// the restore had worked.
    @Test("a restore that finds nothing says so and stays put")
    func restoreFindsNothing() async throws {
        let defaults = try EphemeralDefaults()
        let rig = await makeReadyRig(defaults)
        rig.service.restoreResult = .success(false)

        await rig.viewModel.restore()

        #expect(rig.viewModel.isShowingAlert)
        #expect(rig.viewModel.alert?.title == PurchasesController.RestoreOutcome.nothingToRestore.title)
        #expect(rig.viewModel.shouldDismiss == false)
        #expect(rig.viewModel.didUnlockPro == false)
    }

    @Test("a failed restore reads the same here as it does in Settings")
    func restoreFails() async throws {
        let defaults = try EphemeralDefaults()
        let rig = await makeReadyRig(defaults)
        rig.service.restoreResult = .failure(StoreUnreachable())

        await rig.viewModel.restore()

        #expect(rig.viewModel.isShowingAlert)
        #expect(rig.viewModel.alert?.title == PurchasesController.RestoreOutcome.failed.title)
        #expect(rig.viewModel.alert?.message == PurchasesController.RestoreOutcome.failed.message)
        #expect(rig.viewModel.shouldDismiss == false)
    }
}
