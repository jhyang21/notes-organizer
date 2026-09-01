import NotesOrganizerKit
import Observation

/// What the app currently believes about the plan, in a form SwiftUI watches.
///
/// `EntitlementStore` is shared storage, not an observable object: it is
/// written by RevenueCat's stream in this process and by the organize endpoint
/// in either process, and neither one can tell a screen to redraw. This is the
/// one snapshot every screen reads, so Settings and the capture screen can
/// never disagree about the same month.
///
/// Freshness is by refresh, not by subscription. A write from the share
/// extension happens while the app is away, so `refresh()` on return to the
/// foreground catches everything a Darwin notification would have, at a
/// fraction of the moving parts.
@MainActor
@Observable
final class PlanModel {
    private(set) var isPro: Bool

    /// Tidies left this month, or `nil` when the honest answer is "we don't
    /// know" — a fresh install, a Pro subscription, or counts from a month
    /// that has rolled over. Screens hide the line rather than guess.
    private(set) var remaining: Int?

    @ObservationIgnored
    private let store: EntitlementStore

    init(store: EntitlementStore = .shared) {
        self.store = store
        self.isPro = store.isPro()
        self.remaining = store.cloudRemaining()
    }

    func refresh() {
        isPro = store.isPro()
        remaining = store.cloudRemaining()
    }
}
