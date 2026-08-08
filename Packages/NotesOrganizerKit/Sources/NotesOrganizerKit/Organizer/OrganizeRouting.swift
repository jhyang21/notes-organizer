import Foundation

/// What the preview offers a free user once a plain tidy is on screen: the
/// same text, run again through the cloud. `remaining` is `nil` when the count
/// isn't known — a fresh install, or a month that has rolled over — and the
/// button then says nothing about numbers rather than guessing at one.
public struct PremiumTidyOffer: Equatable, Sendable {
    public let remaining: Int?

    public init(remaining: Int?) {
        self.remaining = remaining
    }

    public var title: String {
        guard let remaining else { return "Premium tidy" }
        return "Premium tidy — \(remaining) left this month"
    }
}

/// The routing decision as both view models make it, in one place because
/// they make it identically: `RoutingPolicy`'s table, plus the two things the
/// table deliberately doesn't know about — where the plan state is stored, and
/// the kill switch.
///
/// The view models need the route before they run anything: two of its
/// outcomes (the consent sheet, the blocked screens) are screens rather than
/// organizers. So this hands back a `Route` first and an organizer second,
/// instead of hiding both behind one call.
public struct OrganizeRouting: Sendable {
    private let store: EntitlementStore
    private let cloudEnabled: Bool
    private let cloud: NoteOrganizing
    private let onDevice: NoteOrganizing

    /// - Parameter cloud: defaults to a `CloudOrganizer` on the same store, so
    ///   the quota a route was decided from is the quota a response overwrites.
    public init(
        store: EntitlementStore = .shared,
        cloudEnabled: Bool = CloudConfig.cloudEnabled,
        cloud: NoteOrganizing? = nil,
        onDevice: NoteOrganizing = FoundationModelOrganizer()
    ) {
        self.store = store
        self.cloudEnabled = cloudEnabled
        self.cloud = cloud ?? CloudOrganizer(store: store)
        self.onDevice = onDevice
    }

    // MARK: - Deciding

    /// - Parameter onDeviceFailure: what `ModelAvailability` says, or `nil`
    ///   when the on-device model can run.
    public func route(
        preference: RoutingPolicy.Preference,
        onDeviceFailure: OrganizeFailure?
    ) -> RoutingPolicy.Route {
        // With the switch off the app is exactly what it was before premium
        // tidies existed: on-device, or the reason it can't be.
        guard cloudEnabled else {
            if let onDeviceFailure { return .blocked(onDeviceFailure) }
            return .onDevice
        }
        return RoutingPolicy.route(
            isPro: store.isPro(),
            cloudRemaining: store.cloudRemaining(),
            onDeviceFailure: onDeviceFailure,
            consentGranted: store.cloudConsentGranted,
            preference: preference
        )
    }

    public func organizer(
        for route: RoutingPolicy.Route,
        source: DiagnosticsSource,
        log: DiagnosticsLog = .shared
    ) -> NoteOrganizing {
        OrganizerRouter(route: route, cloud: cloud, onDevice: onDevice, source: source, log: log)
    }

    // MARK: - Offering

    /// Whether a finished on-device tidy should offer to be redone in the
    /// cloud, and what the button says. `nil` means don't ask: Pro users get
    /// the cloud automatically, and there is nothing to offer someone whose
    /// quota is spent or whose cloud is switched off — the wall belongs on the
    /// screen that tried, not on a preview that worked.
    public func premiumTidyOffer() -> PremiumTidyOffer? {
        guard cloudEnabled, !store.isPro() else { return nil }

        switch route(preference: .forceCloud, onDeviceFailure: nil) {
        case .cloud, .consentNeeded:
            return PremiumTidyOffer(remaining: store.cloudRemaining())
        case .onDevice, .blocked:
            return nil
        }
    }

    // MARK: - Plan and consent

    /// What the app last heard from RevenueCat. Drives what the UI says, never
    /// what the server allows — that is re-checked on every call.
    public var isPro: Bool { store.isPro() }

    public func setCloudConsentGranted(_ granted: Bool) {
        store.setCloudConsentGranted(granted)
    }
}
