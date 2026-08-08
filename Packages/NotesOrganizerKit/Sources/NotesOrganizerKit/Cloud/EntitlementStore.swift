import Foundation

/// What the app believes about the user's plan and this month's premium
/// tidies. A belief, not a ledger: the server counts, and every field here
/// was copied from something the server said. Nothing in this type ever
/// increments a counter of its own, so the worst a stale or tampered value
/// can cost is one round-trip that comes back 429.
public struct PlanState: Codable, Equatable, Sendable {
    /// The free plan's monthly allowance. The server enforces its own copy of
    /// this number; the client keeps one so a fresh install can say "5 left"
    /// before it has called anything.
    public static let freeMonthlyLimit = 5

    public var isPro: Bool
    public var cloudUsed: Int
    public var cloudLimit: Int
    /// The month the counts belong to, as the server labelled it ("2026-08").
    public var monthKey: String

    public init(isPro: Bool = false, cloudUsed: Int = 0, cloudLimit: Int = PlanState.freeMonthlyLimit, monthKey: String = "") {
        self.isPro = isPro
        self.cloudUsed = cloudUsed
        self.cloudLimit = cloudLimit
        self.monthKey = monthKey
    }
}

/// The App-Group-backed store both processes read: the app writes what the
/// server and RevenueCat tell it, the share extension only reads. Best effort
/// in the same way `DiagnosticsLog` is — a build without the group
/// entitlement gets `nil` defaults, every write goes nowhere, and the user
/// loses a remaining-count line rather than a note.
public struct EntitlementStore: @unchecked Sendable {
    // `UserDefaults` is thread-safe but not `Sendable`; same trade as
    // `UserDefaultsDiagnosticsStorage`.
    private let defaults: UserDefaults?

    /// The instance both targets use.
    public static let shared = EntitlementStore(defaults: AppGroup.defaults)

    private enum Key {
        static let planState = "entitlement.planState"
        static let cloudConsent = "entitlement.cloudConsentGranted"
        static let appUserID = "entitlement.appUserID"
    }

    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    // MARK: - Identity

    /// The stable anonymous ID this install is known by — RevenueCat's app
    /// user ID and the organize endpoint's quota key, deliberately the same
    /// string. A custom ID rather than an SDK-generated one because it has to
    /// exist before RevenueCat initializes and be readable by the share
    /// extension, which never links the SDK.
    ///
    /// Read-or-create. With no shared storage there is nothing to read and
    /// nothing to keep, so each call invents a new one — a device in that
    /// state has no quota history worth preserving anyway.
    public func appUserID() -> String {
        if let existing = defaults?.string(forKey: Key.appUserID), !existing.isEmpty {
            return existing
        }
        let created = "tidy:\(UUID().uuidString)"
        defaults?.set(created, forKey: Key.appUserID)
        return created
    }

    // MARK: - Plan

    public func planState() -> PlanState? {
        guard let data = defaults?.data(forKey: Key.planState) else { return nil }
        return try? JSONDecoder().decode(PlanState.self, from: data)
    }

    /// Overwrites the whole state from a server response.
    public func record(_ state: PlanState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults?.set(data, forKey: Key.planState)
    }

    /// Records the quota exactly as the server reported it, keeping whatever
    /// is known about the plan. Never derived, never incremented locally.
    public func recordQuota(used: Int, limit: Int, month: String, isPro: Bool) {
        var state = planState() ?? PlanState()
        state.cloudUsed = used
        state.cloudLimit = limit
        state.monthKey = month
        state.isPro = isPro
        record(state)
    }

    /// Mirrors RevenueCat's view of the subscription. Entitlement is still
    /// re-checked server-side on every call, so this only drives what the UI
    /// says about the plan.
    public func recordIsPro(_ isPro: Bool) {
        var state = planState() ?? PlanState()
        state.isPro = isPro
        record(state)
    }

    public func isPro() -> Bool {
        planState()?.isPro ?? false
    }

    /// How many premium tidies are left, or `nil` when the honest answer is
    /// "we don't know yet" — no stored state, a Pro subscription (unlimited),
    /// or counts from a month that has since rolled over. Callers treat `nil`
    /// optimistically: try the call and let the server say no.
    public func cloudRemaining(now: Date = Date()) -> Int? {
        guard let state = planState(), !state.isPro else { return nil }
        guard state.monthKey == Self.monthKey(for: now) else { return nil }
        return max(0, state.cloudLimit - state.cloudUsed)
    }

    /// UTC, so a user crossing a time zone doesn't gain or lose a month. The
    /// server labels the month the same way; a mismatch only ever reads as
    /// "unknown", which is safe.
    static func monthKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    // MARK: - Consent

    /// Whether the user has agreed to send note text for a premium tidy.
    /// Absent means "not asked yet"; the app shows the sheet, the extension
    /// treats it as no.
    public var cloudConsentGranted: Bool {
        defaults?.bool(forKey: Key.cloudConsent) ?? false
    }

    public func setCloudConsentGranted(_ granted: Bool) {
        defaults?.set(granted, forKey: Key.cloudConsent)
    }
}
