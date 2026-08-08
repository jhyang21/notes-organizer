import NotesOrganizerKit
import RevenueCat
import SwiftUI

/// Everything about the account that isn't capturing a note: which plan the
/// user is on, how many premium tidies are left, the two buttons Apple
/// requires next to a subscription, what leaves the iPhone, and the way in to
/// Diagnostics.
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
    @State private var restoreOutcome: RestoreOutcome?

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
            isPresented: isShowingRestoreOutcome,
            presenting: restoreOutcome
        ) { _ in
            Button("OK") {}
        } message: { outcome in
            Text(outcome.message)
        }
        .task {
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
                Text("Premium tidies are unlimited.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Free plan")
                    .font(.headline)

                if let remaining {
                    Text("Premium tidies left this month: \(remaining)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(PlanState.freeMonthlyLimit) premium tidies a month on the free plan.")
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
            Tidies that run on your iPhone stay on your iPhone — nothing is \
            sent anywhere. A premium tidy sends the note's text over an \
            encrypted connection so a bigger model can organize it, and the \
            text isn't kept once the note comes back.
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
            restoreOutcome = customerInfo.isPro
                ? RestoreOutcome(
                    title: "Purchases restored",
                    message: "TidyNote Pro is active on this iPhone."
                )
                : RestoreOutcome(
                    title: "Nothing to restore",
                    message: "We didn't find a TidyNote Pro subscription on this Apple Account."
                )
        } catch {
            restoreOutcome = RestoreOutcome(
                title: "Couldn't restore",
                message: error.localizedDescription
            )
        }
    }

    /// The alert reads its text from the outcome and its presence from
    /// whether there is one, so there is a single piece of state to get wrong.
    private var isShowingRestoreOutcome: Binding<Bool> {
        Binding(
            get: { restoreOutcome != nil },
            set: { isPresented in
                if !isPresented { restoreOutcome = nil }
            }
        )
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
