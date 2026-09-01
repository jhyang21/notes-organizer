import NotesOrganizerKit
import StoreKit
import SwiftUI

/// Everything about the account that isn't capturing a note: which plan the
/// user is on, how many tidies are left, the two buttons Apple requires next
/// to a subscription, what leaves the iPhone, and — for whoever knows where it
/// is — the way in to Diagnostics.
///
/// The plan lines come from `PlanModel`, so a purchase made on the paywall
/// changes them without this screen asking. It still refreshes on appear: the
/// share extension can spend a tidy while the app is in the background, and
/// walking into Settings is a fine moment to catch up.
struct SettingsScreen: View {
    @Environment(PlanModel.self) private var plan
    @Environment(PurchasesController.self) private var purchases

    @State private var isShowingPaywall = false
    @State private var isShowingManageSubscriptions = false
    /// The last restore's answer, and whether its alert is up. Two pieces of
    /// state rather than one because the alert reads its title while it
    /// animates away: clearing the outcome on dismissal blanked the title on
    /// the way out.
    @State private var restoreOutcome: PurchasesController.RestoreOutcome?
    @State private var isShowingRestoreOutcome = false

    /// Diagnostics is a workbench, not a feature. It stays out of a release
    /// build's Settings until someone taps the version line five times —
    /// enough that nobody finds it by accident, little enough that a
    /// TestFlight tester can be told how over the phone.
    @AppStorage("diagnosticsUnlocked") private var isDiagnosticsUnlocked = false
    @State private var versionTaps = 0

    private static let tapsToRevealDiagnostics = 5
    private static let privacyPolicyURL = URL(string: "https://jhyang21.github.io/notes-organizer/privacy.html")!
    private static let termsURL = URL(string: "https://jhyang21.github.io/notes-organizer/terms.html")!

    var body: some View {
        List {
            planSection
            purchasesSection
            privacySection
            aboutSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingPaywall, onDismiss: { plan.refresh() }) {
            PaywallScreen()
        }
        // Apple's own sheet, in the app, instead of throwing the user out to
        // Safari and asking them to find the subscription again.
        .manageSubscriptionsSheet(isPresented: $isShowingManageSubscriptions)
        .alert(
            restoreOutcome?.title ?? "",
            isPresented: $isShowingRestoreOutcome,
            presenting: restoreOutcome
        ) { _ in
            Button("OK") {}
        } message: { outcome in
            Text(outcome.message)
        }
        // "Nothing to restore" and "failed" are both just news; only an
        // actual restore is a success worth feeling.
        .sensoryFeedback(.success, trigger: restoreOutcome) { _, new in new == .restored }
        .onAppear {
            plan.refresh()
        }
    }

    // MARK: - Plan

    @ViewBuilder
    private var planSection: some View {
        Section("Plan") {
            if plan.isPro {
                Label("TidyNote Pro", systemImage: "sparkles")
                    .font(.headline)
                Text("Tidies are unlimited.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Free plan")
                    .font(.headline)

                if let remaining = plan.remaining {
                    Text("Tidies left this month: \(remaining)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(PlanState.freeMonthlyLimit) tidies a month on the free plan.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // No price here on purpose: the paywall renders the live
                // StoreKit prices and terms, so a second copy in Settings is
                // only ever a chance to be wrong.
                Button("Go Pro") {
                    isShowingPaywall = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Purchases

    private var purchasesSection: some View {
        Section {
            Button {
                Task { await restore() }
            } label: {
                HStack {
                    Text("Restore Purchases")
                    if purchases.isRestoring {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(purchases.isRestoring)

            Button("Manage Subscription") {
                isShowingManageSubscriptions = true
            }
        } footer: {
            Text("Restore if you've subscribed before on another iPhone or after reinstalling.")
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section("Privacy") {
            Text("""
            Your recording and your note's text are sent over an encrypted \
            connection so they can be transcribed and organized. We don't keep \
            either one once the note comes back.
            """)
            .font(.footnote)
            .foregroundStyle(.secondary)

            Link("Privacy Policy", destination: Self.privacyPolicyURL)
            Link("Terms of Use", destination: Self.termsURL)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            if isDiagnosticsVisible {
                NavigationLink {
                    DiagnosticsScreen()
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
            }
        } footer: {
            Text(versionLabel)
                .frame(maxWidth: .infinity, alignment: .center)
                // A footer is not a control, so the tap needs somewhere to
                // land: without this only the glyphs themselves are hittable.
                .contentShape(Rectangle())
                .onTapGesture { registerVersionTap() }
        }
    }

    private var isDiagnosticsVisible: Bool {
        #if DEBUG
        return true
        #else
        return isDiagnosticsUnlocked
        #endif
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "TidyNote \(version) (\(build))"
    }

    // MARK: - Actions

    private func registerVersionTap() {
        guard !isDiagnosticsUnlocked else { return }
        versionTaps += 1
        if versionTaps >= Self.tapsToRevealDiagnostics {
            isDiagnosticsUnlocked = true
        }
    }

    private func restore() async {
        restoreOutcome = await purchases.restore()
        isShowingRestoreOutcome = true
    }
}

#Preview {
    let plan = PlanModel()

    NavigationStack {
        SettingsScreen()
    }
    .environment(plan)
    .environment(PurchasesController(plan: plan))
}
