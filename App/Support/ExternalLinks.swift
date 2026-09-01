import Foundation

/// The hosted pages the app links out to. One owner, because two screens now
/// point at the privacy policy: a copy in each is a copy that can drift, and a
/// stale policy link is the one broken link App Review notices.
enum ExternalLinks {
    static let privacyPolicy = URL(string: "https://jhyang21.github.io/notes-organizer/privacy.html")!
    static let terms = URL(string: "https://jhyang21.github.io/notes-organizer/terms.html")!
}
