import Foundation

/// The routing decision as both view models make it, in one place because
/// they make it identically: `RoutingPolicy`'s table, plus the one thing the
/// table deliberately doesn't know about — where the plan state is stored.
///
/// The view models need the route before they run anything: two of its
/// outcomes (the first-run screen, the quota wall) are screens rather than
/// organizers. So this hands back a `Route` first and an organizer second,
/// instead of hiding both behind one call. It is also the single place a
/// `CloudOrganizer` is built, so the quota a route was decided from is the
/// quota a response overwrites.
public struct OrganizeRouting: Sendable {
    private let store: EntitlementStore
    private let cloud: NoteOrganizing & VoiceOrganizing

    /// - Parameter cloud: defaults to a `CloudOrganizer` on the same store.
    ///   Tests and previews pass a `MockOrganizer` instead. One object covers
    ///   text and voice, because one service does both.
    ///
    /// The default organizer is the only one that attests. The shared
    /// `DeviceAttestor` keys itself by bundle id, so the app and the share
    /// extension each end up with a key of their own.
    public init(store: EntitlementStore = .shared, cloud: (NoteOrganizing & VoiceOrganizing)? = nil) {
        self.store = store
        self.cloud = cloud ?? CloudOrganizer(store: store, attestor: DeviceAttestor.shared)
    }

    // MARK: - Deciding

    /// - Parameter consentGrantedThisSession: for a device where the App Group
    ///   write went nowhere. The user answered; asking again every run would
    ///   be the app's problem being taken out on them.
    public func route(consentGrantedThisSession: Bool = false) -> RoutingPolicy.Route {
        RoutingPolicy.route(
            isPro: store.isPro(),
            cloudRemaining: store.cloudRemaining(),
            consentGranted: store.cloudConsentGranted || consentGrantedThisSession
        )
    }

    public func organizer() -> NoteOrganizing { cloud }

    /// The same object, for a run that starts from a recording rather than
    /// from text. Handed back separately so a caller can only ask for the
    /// path it actually has input for.
    public func voiceOrganizer() -> VoiceOrganizing { cloud }

    // MARK: - Plan and consent

    /// What the app last heard from RevenueCat. Drives what the UI says, never
    /// what the server allows — that is re-checked on every call.
    public var isPro: Bool { store.isPro() }

    public func setCloudConsentGranted(_ granted: Bool) {
        store.setCloudConsentGranted(granted)
    }
}
