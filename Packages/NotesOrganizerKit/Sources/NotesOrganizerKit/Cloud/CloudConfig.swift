import Foundation

/// Where premium tidies go and the key that gets them in the door.
///
/// The key here is the project's publishable key, which is meant to ship in
/// clients — it authenticates the app, not the user, and every call it can
/// make is rate-limited and quota-capped on the server. The key that costs
/// money never leaves the edge function.
public struct CloudConfig: Sendable {
    public let functionsURL: URL
    public let anonKey: String

    public init(functionsURL: URL, anonKey: String) {
        self.functionsURL = functionsURL
        self.anonKey = anonKey
    }

    /// The relora-prod project, which TidyNote shares under the `tidynote_`
    /// naming rule — the function this key can reach is `tidynote_organize`
    /// and nothing else.
    public static let production = CloudConfig(
        functionsURL: URL(string: "https://qcooviiralmdnfvbrtae.supabase.co/functions/v1")!,
        anonKey: "sb_publishable_GNjOCWCE_BcrdGKHPvl_sw_QVeRssb7"
    )

    /// The kill switch. Every client milestone before M11 merges dark and
    /// auto-ships to TestFlight, so the builds in between must not be able to
    /// call a half-built endpoint. M11 flips this to `true` as its last step;
    /// until then the view models route everything on-device.
    ///
    /// Read at the call site rather than inside `RoutingPolicy`, which stays a
    /// pure statement of the plan's routing table.
    public static let cloudEnabled = false
}
