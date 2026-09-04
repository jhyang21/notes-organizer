import Foundation

/// The `tidynote://` links that reach the app from outside it: the Lock Screen
/// widget, the Control Center control, Siri, and the two share-extension dead
/// ends only the app can answer.
///
/// One definition rather than four, because the app parses these strings and
/// three separate binaries build them. A scheme typed out twice is a widget
/// whose tap does nothing, and nothing in a build would say so.
public enum QuickCaptureLink: String, CaseIterable, Sendable {
    /// Bring the app to the front and leave it where the user left it.
    case open
    /// Start recording as soon as the app is on screen.
    case record
    /// Open TidyNote Pro.
    case paywall

    public static let scheme = "tidynote"

    /// The query item that carries the `QuickCaptureToken` on a `record` URL.
    static let tokenQueryName = "t"

    /// The bare URL for a case, with no token on it. What `open` and `paywall`
    /// use, and what a widget falls back to when it has no token to send.
    ///
    /// Force-unwrapped, and safe to be: the string is the scheme and a
    /// lowercase ASCII case name, so it either parses everywhere or nowhere.
    /// `QuickCaptureLinkTests` builds every case, which puts a case that
    /// didn't parse in front of CI instead of on someone's Lock Screen.
    public var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }

    /// The URL that actually starts a recording. Only a caller that can read
    /// the App Group can build one, which is the point: any app can open our
    /// scheme, so the token is what separates our widget from theirs.
    public static func recordURL(token: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = record.rawValue
        components.queryItems = [URLQueryItem(name: tokenQueryName, value: token)]
        return components.url ?? record.url
    }

    /// What an arriving URL asks for, or `nil` when it asks for nothing this
    /// version knows — a bare `tidynote://`, a link from a later release, a URL
    /// that isn't ours. Doing nothing is the right answer to all three: opening
    /// the URL already brought the app to the front.
    ///
    /// A `record` URL has to carry a token this app minted. One that doesn't is
    /// answered with `open` rather than ignored: whoever sent it has already
    /// brought the app forward, and the honest result is the app on screen with
    /// the microphone off.
    public static func route(_ url: URL, acceptedTokens: [String]) -> QuickCaptureLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        // `tidynote://record` puts the target in the host. A hand-typed
        // `tidynote:///record` puts it in the path instead, and means the same
        // thing to the person who typed it.
        let target = url.host()?.lowercased()
            ?? url.pathComponents.first(where: { $0 != "/" })?.lowercased()
        guard let link = target.flatMap(QuickCaptureLink.init(rawValue:)) else { return nil }
        guard link == .record else { return link }

        let sent = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == tokenQueryName })?
            .value
        guard let sent, acceptedTokens.contains(sent) else { return .open }
        return .record
    }
}
