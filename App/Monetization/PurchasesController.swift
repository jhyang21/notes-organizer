import Foundation
import NotesOrganizerKit
import Observation

/// Everything the app does about a subscription: start the store SDK, follow
/// what it says, restore on request — and write what it learns to the App
/// Group, which is the only way the share extension ever hears about Pro.
///
/// Every `recordIsPro` in the app happens here: one owner means one answer,
/// and a stream that stops when this object does.
///
/// Nothing here decides whether a tidy is allowed. The server re-checks
/// entitlement on every call; what the store learns from this file only drives
/// what the UI says about the plan.
@MainActor
@Observable
final class PurchasesController {
    /// What a restore found, in the user's terms. The failure case says the
    /// same thing however it failed: a StoreKit error string is the SDK
    /// talking to us, not to the person holding the phone.
    enum RestoreOutcome: Equatable {
        case restored
        case nothingToRestore
        case failed

        var title: String {
            switch self {
            case .restored: "Purchases restored"
            case .nothingToRestore: "Nothing to restore"
            case .failed: "Couldn't restore purchases"
            }
        }

        var message: String {
            switch self {
            case .restored: "TidyNote Pro is active on this iPhone."
            case .nothingToRestore: "We didn't find a TidyNote Pro subscription on this Apple Account."
            case .failed: "Check your connection and try again."
            }
        }
    }

    /// A restore is in flight. Read by whichever screen offered the button.
    private(set) var isRestoring = false

    @ObservationIgnored private let service: any PurchaseService
    @ObservationIgnored private let store: EntitlementStore
    @ObservationIgnored private let plan: PlanModel
    @ObservationIgnored private let log: DiagnosticsLog
    @ObservationIgnored private let entitlementStream = CancellableTask()

    init(
        plan: PlanModel,
        service: any PurchaseService = RevenueCatPurchaseService(),
        store: EntitlementStore = .shared,
        log: DiagnosticsLog = .shared
    ) {
        self.plan = plan
        self.service = service
        self.store = store
        self.log = log
    }

    deinit {
        entitlementStream.cancel()
    }

    /// Starts the SDK and begins following the customer. Safe to call more
    /// than once: the second call returns without touching either.
    func configure() {
        guard !service.isConfigured else { return }

        service.configure(appUserID: store.appUserID())

        entitlementStream.set(Task { [weak self] in
            guard let updates = self?.service.entitlementUpdates() else { return }
            for await isPro in updates {
                guard let self else { break }
                self.recordEntitlement(isPro: isPro)
            }
        })
    }

    /// The one write. Called by the stream and by the paywall, whose own sheet
    /// does the buying and hands back what it saw.
    func recordEntitlement(isPro: Bool) {
        store.recordIsPro(isPro)
        plan.refresh()
    }

    /// Apple requires a restore button, and it has to be honest about finding
    /// nothing — "restored" on a device that owns no subscription is worse
    /// than useless.
    func restore() async -> RestoreOutcome {
        isRestoring = true
        defer { isRestoring = false }

        do {
            let isPro = try await service.restore()
            recordEntitlement(isPro: isPro)
            return isPro ? .restored : .nothingToRestore
        } catch {
            log.recordEvent(source: .app, message: "Restore failed: \(error.localizedDescription)")
            return .failed
        }
    }
}

/// A task somewhere `deinit` can reach it. `deinit` runs off the main actor,
/// and cancelling there is the whole point of owning the stream rather than
/// detaching it; the lock is what makes that reach legal.
private final class CancellableTask: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) {
        lock.withLock { self.task = task }
    }

    func cancel() {
        let task = lock.withLock {
            let task = self.task
            self.task = nil
            return task
        }
        task?.cancel()
    }
}
