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

    /// Force-unwrapped, and safe to be: the string is the scheme and a
    /// lowercase ASCII case name, so it either parses everywhere or nowhere.
    /// `QuickCaptureLinkTests` builds every case, which puts a case that
    /// didn't parse in front of CI instead of on someone's Lock Screen.
    public var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }

    /// What an arriving URL asks for, or `nil` when it asks for nothing this
    /// version knows — a bare `tidynote://`, a link from a later release, a URL
    /// that isn't ours. Doing nothing is the right answer to all three: opening
    /// the URL already brought the app to the front.
    public static func route(_ url: URL) -> QuickCaptureLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        // `tidynote://record` puts the target in the host. A hand-typed
        // `tidynote:///record` puts it in the path instead, and means the same
        // thing to the person who typed it.
        let target = url.host()?.lowercased()
            ?? url.pathComponents.first(where: { $0 != "/" })?.lowercased()
        return target.flatMap(QuickCaptureLink.init(rawValue:))
    }
}
