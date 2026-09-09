import NotesOrganizerKit
import SwiftUI

/// TidyNote Pro, as a sheet: what Pro is, what the two plans cost, and one
/// button to buy the selected one.
///
/// Every price and every sentence on this screen comes from
/// `PaywallViewModel`, and every price it holds came live from the App Store —
/// nothing here is written down, and nothing here decides anything. The
/// screen's own job is the part a view model can't do: draw it, scale it,
/// read it out, and get out of the user's way once the store has answered.
struct PaywallScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewModel: PaywallViewModel

    init(viewModel: PaywallViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        // Only the alert needs a binding; everything else reads the model
        // straight off the state.
        @Bindable var bindable = viewModel

        NavigationStack {
            content
                .navigationTitle("TidyNote Pro")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close")
                    }
                }
        }
        .task { await viewModel.load() }
        .alert(
            viewModel.alert?.title ?? "",
            isPresented: $bindable.isShowingAlert,
            presenting: viewModel.alert
        ) { _ in
            Button("OK") {}
        } message: { Text($0.message) }
        .sensoryFeedback(.success, trigger: viewModel.didUnlockPro) { _, new in new }
        // The one thing the view model can't do for itself.
        .onChange(of: viewModel.shouldDismiss) { _, shouldDismiss in
            if shouldDismiss { dismiss() }
        }
        // A sheet that swaps a spinner for a list of prices doesn't move
        // VoiceOver's focus on its own, and a dead end announces nothing at
        // all — so each phase says what it is when it arrives.
        .onChange(of: viewModel.phase) { _, phase in
            if let announcement = Self.announcement(for: phase) {
                AccessibilityNotification.Announcement(announcement).post()
            }
        }
        // A swipe away mid-purchase leaves the store's sheet talking to a
        // screen that has gone.
        .interactiveDismissDisabled(viewModel.isPurchasing)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .checkingConnection, .loading:
            ProgressView()
                .accessibilityLabel("Loading plans")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .offline:
            offlineView
        case .unavailable:
            unavailableView
        case .ready(let offer):
            readyView(offer)
        }
    }

    // MARK: - Dead ends

    /// Not `UnavailableView`: its copy is about a tidy, and this dead end is
    /// about the store.
    private var offlineView: some View {
        NoticeView(
            symbol: "wifi.slash",
            title: String(localized: "You're offline"),
            message: String(localized: "TidyNote Pro needs a connection to show prices and take a payment. Try again when you're back online.")
        ) {
            noticeActions
        }
    }

    /// Online, and the store still had nothing to sell — a first launch that
    /// beat StoreKit to it, or an offering being edited. Same two ways out.
    private var unavailableView: some View {
        NoticeView(
            symbol: "exclamationmark.triangle",
            title: String(localized: "Couldn't load the plans"),
            message: String(localized: "We couldn't reach the App Store for prices. Check your connection and try again.")
        ) {
            noticeActions
        }
    }

    private var noticeActions: some View {
        VStack(spacing: 12) {
            Button("Try Again") {
                Task { await viewModel.retry() }
            }
            .buttonStyle(.borderedProminent)

            Button("Close") { dismiss() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - The offer

    /// The footer is pinned to the bottom at every normal text size, and put
    /// back into the scroll at accessibility sizes: a call to action, its
    /// small print and three links can be taller than the screen there, and a
    /// pinned bar that tall would leave nothing to read above it.
    @ViewBuilder
    private func readyView(_ offer: PaywallOffer) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            scrollContent(offer, includesFooter: true)
        } else {
            scrollContent(offer, includesFooter: false)
                .safeAreaInset(edge: .bottom) { footer }
        }
    }

    private func scrollContent(_ offer: PaywallOffer, includesFooter: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                benefits
                plans(offer)

                if includesFooter { footer }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tidy as much as you like")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            Text(verbatim: viewModel.supportingLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 16) {
            BenefitRow(
                symbol: "infinity",
                title: "Unlimited tidies",
                detail: "The free plan stops at \(PlanState.freeMonthlyLimit) a month; Pro keeps going."
            )
            BenefitRow(
                symbol: "mic",
                title: "Voice or shared notes",
                detail: "Record a ramble, or share a messy note in from Apple Notes or any app."
            )
            BenefitRow(
                symbol: "checklist",
                title: "Organized, never summarized",
                detail: "Every fact, name, number, and date you said stays in the note."
            )
            BenefitRow(
                symbol: "lock.shield",
                title: "Nothing kept",
                detail: "Your recording and your note aren't stored once the note comes back."
            )
        }
    }

    private func plans(_ offer: PaywallOffer) -> some View {
        VStack(spacing: 12) {
            ForEach(offer.plans) { plan in
                PlanCard(
                    title: viewModel.title(for: plan),
                    priceLine: viewModel.priceLine(for: plan),
                    pricePerMonthLine: viewModel.pricePerMonthLine(for: plan),
                    savingsLine: viewModel.isRecommended(plan) ? viewModel.savingsLine : nil,
                    isRecommended: viewModel.isRecommended(plan),
                    isSelected: viewModel.isSelected(plan),
                    label: viewModel.accessibilityLabel(for: plan)
                ) {
                    viewModel.select(plan.id)
                }
            }
        }
        .animation(reduceMotion ? nil : .default, value: viewModel.selectedPlanID)
    }

    // MARK: - The footer

    private var footer: some View {
        VStack(spacing: 12) {
            Button {
                Task { await viewModel.purchase() }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isPurchasing {
                        ProgressView()
                            .tint(.white)
                            .accessibilityLabel("Purchasing")
                    }

                    Text(verbatim: viewModel.callToAction)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(viewModel.isBusy)

            Text(verbatim: viewModel.billingLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            links
        }
        .padding()
        .frame(maxWidth: .infinity)
        // Opaque on purpose: the content scrolls under it.
        .background(.background)
    }

    /// The three Apple expects on a paywall. Stacked at accessibility sizes,
    /// where three of them side by side would be one word per line.
    private var links: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 16))

        return layout {
            Button("Restore Purchases") {
                Task { await viewModel.restore() }
            }
            .disabled(viewModel.isBusy)

            Link("Terms of Use", destination: ExternalLinks.terms)
            Link("Privacy Policy", destination: ExternalLinks.privacyPolicy)
        }
        .font(.footnote)
    }

    // MARK: - VoiceOver

    private static func announcement(for phase: PaywallViewModel.Phase) -> String? {
        switch phase {
        case .ready: return String(localized: "TidyNote Pro")
        case .offline: return String(localized: "You're offline")
        case .unavailable: return String(localized: "Couldn't load the plans")
        case .checkingConnection, .loading: return nil
        }
    }
}

/// One reason to subscribe: a tinted symbol in a column of its own, a
/// headline, and the sentence that makes it true. The same idiom as
/// `HowToTidyScreen.step`, so the two sheets read as one app.
private struct BenefitRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    // The symbol column scales with the body text it sits beside, so the
    // headlines stay aligned at every text size.
    @ScaledMetric(relativeTo: .body) private var symbolWidth: CGFloat = 28

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .frame(width: symbolWidth)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        // A benefit is one thing to say, not two.
        .accessibilityElement(children: .combine)
    }
}

/// One plan, as a card the whole of which is the button. Selection is a
/// border, a filled checkmark and the `.isSelected` trait together — never
/// colour on its own, which is invisible to a third of the people who will
/// see this screen.
private struct PlanCard: View {
    let title: String
    let priceLine: String
    let pricePerMonthLine: String?
    let savingsLine: String?
    let isRecommended: Bool
    let isSelected: Bool
    /// The whole card in one sentence, assembled by the view model — the
    /// pieces below are laid out for the eye, not for the ear.
    let label: String
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            layout {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(verbatim: title)
                            .font(.headline)

                        if isRecommended { badge }
                    }

                    Text(verbatim: priceLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // The per-month price sits at the far end of the row, and
                // directly under the title once the row becomes a column.
                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 12)
                }

                VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
                    if let pricePerMonthLine {
                        Text(verbatim: pricePerMonthLine)
                            .font(.subheadline)
                    }

                    if let savingsLine {
                        Text(verbatim: savingsLine)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 44)
            // The gaps between the pieces are part of the button.
            .contentShape(Rectangle())
            .overlay { border }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Side by side normally; stacked once the text is large enough that a
    /// price and a saving beside a title would each be two words wide.
    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
    }

    private var badge: some View {
        Text("Best value")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }

    @ViewBuilder
    private var border: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 2)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }
}

#if DEBUG

/// A store with no store behind it: the previews below need prices, an
/// eligibility answer and a purchase that never finishes, and none of those
/// can come from a Mac running a canvas.
@MainActor
private final class PreviewPurchaseService: PurchaseService {
    var isConfigured = true

    private let offer: PaywallOffer?
    private let eligiblePlanIDs: Set<String>
    private let stallsOnLoad: Bool
    private let stallsOnPurchase: Bool

    init(
        offer: PaywallOffer?,
        eligiblePlanIDs: Set<String> = [],
        stallsOnLoad: Bool = false,
        stallsOnPurchase: Bool = false
    ) {
        self.offer = offer
        self.eligiblePlanIDs = eligiblePlanIDs
        self.stallsOnLoad = stallsOnLoad
        self.stallsOnPurchase = stallsOnPurchase
    }

    func configure(appUserID: String) {}

    func entitlementUpdates() -> AsyncStream<Bool> {
        AsyncStream { continuation in continuation.finish() }
    }

    func restore() async throws -> Bool { false }

    func currentOffer() async throws -> PaywallOffer? {
        if stallsOnLoad { try await Task.sleep(for: .seconds(600)) }
        return offer
    }

    func trialEligibility(for productIDs: [String]) async -> Set<String> {
        eligiblePlanIDs
    }

    func purchase(planID: String) async throws -> PurchaseResult {
        if stallsOnPurchase { try await Task.sleep(for: .seconds(600)) }
        return .purchased(isPro: true)
    }
}

private struct PreviewConnectivity: ConnectivityChecking {
    let isOnlineValue: Bool

    func isOnline() async -> Bool { isOnlineValue }
}

private let previewAnnualID = "tidynote.pro.annual"
private let previewMonthlyID = "tidynote.pro.monthly"

private let previewPlans: [PaywallPlan] = [
    PaywallPlan(
        id: previewAnnualID,
        period: .year,
        price: 39.99,
        currencyCode: "USD",
        localizedPrice: "$39.99",
        localizedPricePerMonth: "$3.33",
        trialDays: 7
    ),
    PaywallPlan(
        id: previewMonthlyID,
        period: .month,
        price: 4.99,
        currencyCode: "USD",
        localizedPrice: "$4.99",
        localizedPricePerMonth: nil,
        trialDays: 7
    ),
]

@MainActor
private func previewModel(
    plans: [PaywallPlan] = previewPlans,
    eligiblePlanIDs: Set<String> = [previewAnnualID, previewMonthlyID],
    isOnline: Bool = true,
    stallsOnLoad: Bool = false,
    stallsOnPurchase: Bool = false
) -> PaywallViewModel {
    let service = PreviewPurchaseService(
        offer: PaywallOffer.make(from: plans),
        eligiblePlanIDs: eligiblePlanIDs,
        stallsOnLoad: stallsOnLoad,
        stallsOnPurchase: stallsOnPurchase
    )
    // No App Group in a preview, so the store is one that writes nowhere.
    let store = EntitlementStore(defaults: nil)
    let purchases = PurchasesController(
        plan: PlanModel(store: store),
        service: service,
        store: store
    )
    return PaywallViewModel(
        purchases: purchases,
        connectivity: PreviewConnectivity(isOnlineValue: isOnline)
    )
}

#Preview("Trial available") {
    PaywallScreen(viewModel: previewModel())
}

#Preview("Trial already used") {
    PaywallScreen(viewModel: previewModel(eligiblePlanIDs: []))
}

#Preview("One plan") {
    PaywallScreen(viewModel: previewModel(plans: [previewPlans[1]]))
}

#Preview("Loading") {
    PaywallScreen(viewModel: previewModel(stallsOnLoad: true))
}

#Preview("Nothing to sell") {
    PaywallScreen(viewModel: previewModel(plans: []))
}

#Preview("Offline") {
    PaywallScreen(viewModel: previewModel(isOnline: false))
}

#Preview("Purchasing") {
    // The screen's own task loads the offer; this one waits for a plan to be
    // selected and then starts a purchase that never comes back.
    let model = previewModel(stallsOnPurchase: true)

    PaywallScreen(viewModel: model)
        .task {
            while model.selectedPlanID == nil {
                try? await Task.sleep(for: .milliseconds(20))
            }
            await model.purchase()
        }
}

#Preview("Largest text size") {
    PaywallScreen(viewModel: previewModel())
        .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("Dark") {
    PaywallScreen(viewModel: previewModel())
        .preferredColorScheme(.dark)
}

#endif
