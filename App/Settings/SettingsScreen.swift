import NotesOrganizerKit
import RevenueCat
import SwiftUI

/// Everything about the account that isn't capturing a note: which plan the
/// user is on, how many tidies are left, the two buttons Apple requires next
/// to a subscription, what leaves the iPhone, and the way in to Diagnostics.
///
/// The plan lines read from `EntitlementStore`, which is plain shared
/// storage rather than anything observable, so the screen pulls a snapshot
/// when it appears and again after the paywall closes. That is enough: nothing
/// else changes the plan while this screen is on top.
struct SettingsScreen: View {
    @State private var isPro = false
    @State private var remaining: Int?
    @State private var isShowingPaywall = false
    @State private var isRestoring = false
    /// The last restore's answer, and whether its alert is up. Two pieces of
    /// state rather than one because the alert reads its title while it
    /// animates away: clearing the outcome on dismissal blanked the title on
    /// the way out.
    @State private var restoreOutcome: RestoreOutcome?
    @State private var isShowingRestoreOutcome = false

    @Environment(\.openURL) private var openURL

    private static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    var body: some View {
        List {
            planSection
            purchasesSection
            privacySection

            Section {
                NavigationLink {
                    DiagnosticsScreen()
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingPaywall, onDismiss: refresh) {
            PaywallScreen()
        }
        .alert(
            restoreOutcome?.title ?? "",
            isPresented: $isShowingRestoreOutcome,
            presenting: restoreOutcome
        ) { _ in
            Button("OK") {}
        } message: { outcome in
            Text(outcome.message)
        }
        .onAppear {
            refresh()
        }
    }

    // MARK: - Plan

    @ViewBuilder
    private var planSection: some View {
        Section("Plan") {
            if isPro {
                Label("TidyNote Pro", systemImage: "sparkles")
                    .font(.headline)
                Text("Tidies are unlimited.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Free plan")
                    .font(.headline)

                if let remaining {
                    Text("Tidies left this month: \(remaining)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(PlanState.freeMonthlyLimit) tidies a month on the free plan.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

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
                    if isRestoring {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isRestoring)

            Button("Manage Subscription") {
                openURL(Self.manageSubscriptionsURL)
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
        }
    }

    // MARK: - Actions

    private func refresh() {
        isPro = EntitlementStore.shared.isPro()
        remaining = EntitlementStore.shared.cloudRemaining()
    }

    /// Apple requires a restore button, and it has to be honest about finding
    /// nothing — "restored" on a device that owns no subscription is worse
    /// than useless.
    private func restore() async {
        isRestoring = true
        defer { isRestoring = false }

        do {
            let customerInfo = try await Purchases.shared.restorePurchases()
            EntitlementStore.shared.recordIsPro(customerInfo.isPro)
            refresh()
            present(customerInfo.isPro
                ? RestoreOutcome(
                    title: "Purchases restored",
                    message: "TidyNote Pro is active on this iPhone."
                )
                : RestoreOutcome(
                    title: "Nothing to restore",
                    message: "We didn't find a TidyNote Pro subscription on this Apple Account."
                ))
        } catch {
            present(RestoreOutcome(
                title: "Couldn't restore",
                message: error.localizedDescription
            ))
        }
    }

    private func present(_ outcome: RestoreOutcome) {
        restoreOutcome = outcome
        isShowingRestoreOutcome = true
    }

    private struct RestoreOutcome {
        let title: String
        let message: String
    }
}

#Preview {
    NavigationStack {
        SettingsScreen()
    }
}
