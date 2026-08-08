import Foundation

/// Which organizer should handle this note, decided before anything runs.
/// Pure and table-tested, because this is where the product's promises live:
/// what the free plan gets, what a subscription buys, and where the user hits
/// a wall instead of a downgrade.
public enum RoutingPolicy {
    /// What the user asked for. `.forceCloud` is the explicit "premium tidy"
    /// tap; everything else is `.automatic`.
    public enum Preference: Equatable, Sendable {
        case automatic
        case forceCloud
    }

    public enum Route: Equatable, Sendable {
        case onDevice
        /// `fallbackOnDevice` is only ever true when the user didn't ask for
        /// the cloud specifically. Silently substituting a plain tidy for the
        /// premium one somebody tapped would be a lie about what they got.
        case cloud(fallbackOnDevice: Bool)
        /// Nothing can run. Show this failure.
        case blocked(OrganizeFailure)
        /// The cloud is the way forward and the user hasn't agreed to it yet.
        /// The app asks; the share extension can't, and treats it as blocked.
        case consentNeeded
    }

    /// - Parameters:
    ///   - cloudRemaining: premium tidies left this month, or `nil` when
    ///     that isn't known — a fresh install, or counts from a month that has
    ///     rolled over. Unknown is treated optimistically: try, and let the
    ///     server's 429 be the wall.
    ///   - onDeviceFailure: why the on-device model can't run, or `nil` if it
    ///     can.
    public static func route(
        isPro: Bool,
        cloudRemaining: Int?,
        onDeviceFailure: OrganizeFailure?,
        consentGranted: Bool,
        preference: Preference
    ) -> Route {
        let onDeviceAvailable = onDeviceFailure == nil

        switch preference {
        case .forceCloud:
            return cloud(isPro: isPro, remaining: cloudRemaining, consentGranted: consentGranted, fallbackOnDevice: false)

        case .automatic:
            if isPro {
                return cloud(
                    isPro: true,
                    remaining: cloudRemaining,
                    consentGranted: consentGranted,
                    fallbackOnDevice: onDeviceAvailable
                )
            }
            // The free tier's unlimited path. Nothing leaves the iPhone, so
            // there is no consent to ask for and no quota to spend.
            if onDeviceAvailable { return .onDevice }
            return cloud(isPro: false, remaining: cloudRemaining, consentGranted: consentGranted, fallbackOnDevice: false)
        }
    }

    /// The two gates every cloud route passes, in the only order that makes
    /// sense: quota can't be spent by someone who hasn't agreed to spend it.
    private static func cloud(isPro: Bool, remaining: Int?, consentGranted: Bool, fallbackOnDevice: Bool) -> Route {
        guard consentGranted else { return .consentNeeded }
        if !isPro, let remaining, remaining <= 0 { return .blocked(.cloudQuotaExhausted) }
        return .cloud(fallbackOnDevice: fallbackOnDevice)
    }
}

/// Runs the route a `RoutingPolicy` decided. A `NoteOrganizing` like any
/// other, so `OrganizeRun` and both view models' run loops are unchanged —
/// they still call `organize(_:)` and get a note or a failure.
///
/// The route is fixed at construction. Deciding once, before the run, is what
/// lets the view models show the consent sheet and the quota wall from the
/// same decision that picks the organizer.
public struct OrganizerRouter: NoteOrganizing {
    private let route: RoutingPolicy.Route
    private let cloud: NoteOrganizing
    private let onDevice: NoteOrganizing
    private let source: DiagnosticsSource
    private let log: DiagnosticsLog

    public init(
        route: RoutingPolicy.Route,
        cloud: NoteOrganizing,
        onDevice: NoteOrganizing,
        source: DiagnosticsSource,
        log: DiagnosticsLog = .shared
    ) {
        self.route = route
        self.cloud = cloud
        self.onDevice = onDevice
        self.source = source
        self.log = log
    }

    public func organize(_ text: String) async throws -> OrganizedNote {
        switch route {
        case .onDevice:
            return try await onDevice.organize(text)

        case .cloud(let fallbackOnDevice):
            return try await organizeInCloud(text, fallbackOnDevice: fallbackOnDevice)

        case .blocked(let failure):
            throw failure

        case .consentNeeded:
            // The view models ask before they run, so this arm is a backstop
            // for a caller that didn't. Refusing beats sending the text.
            log.recordEvent(source: source, message: "Organize skipped: cloud consent not granted")
            throw OrganizeFailure.cloudConsentNeeded
        }
    }

    private func organizeInCloud(_ text: String, fallbackOnDevice: Bool) async throws -> OrganizedNote {
        do {
            return try await cloud.organize(text)
        } catch is CancellationError {
            // Cancelling isn't failing, so it must not trigger a fallback that
            // starts a whole second organize the user didn't ask for.
            throw CancellationError()
        } catch {
            guard fallbackOnDevice else { throw error }
            log.recordEvent(source: source, message: "Cloud organize failed, retrying on-device: \(error)")
            return try await onDevice.organize(text)
        }
    }
}
