import Foundation

/// What happens to a note, decided before anything runs. There is one
/// organizer now, so this isn't a choice between models — it is the two
/// questions every tidy has to answer first: has the user been told what
/// TidyNote sends, and is there anything left this month.
///
/// Pure and table-tested, because this is where the product's promises live:
/// what the free plan gets, what a subscription buys, and where the user hits
/// a wall instead of a note.
public enum RoutingPolicy {
    public enum Route: Equatable, Sendable {
        case cloud
        /// The user hasn't been told what TidyNote sends yet. The app shows
        /// the first-run screen; the share extension can't ask, so it points
        /// at the app.
        case consentNeeded
        /// Nothing can run. Show this failure.
        case blocked(OrganizeFailure)
    }

    /// - Parameter cloudRemaining: tidies left this month, or `nil` when that
    ///   isn't known — a fresh install, or counts from a month that has rolled
    ///   over. Unknown is treated optimistically: try, and let the server's
    ///   429 be the wall.
    public static func route(isPro: Bool, cloudRemaining: Int?, consentGranted: Bool) -> Route {
        // Consent comes first: nobody spends a tidy they haven't agreed to.
        guard consentGranted else { return .consentNeeded }
        // Pro is never walled — the server reports a limit for it, and
        // rendering that limit as a countdown would be a lie.
        if !isPro, let cloudRemaining, cloudRemaining <= 0 { return .blocked(.cloudQuotaExhausted) }
        return .cloud
    }
}
