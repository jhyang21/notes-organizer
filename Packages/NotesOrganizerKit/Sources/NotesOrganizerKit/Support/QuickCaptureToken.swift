import Foundation

/// The secret that tells the app's own widget apart from anything else that
/// can open a `tidynote://` URL. Any app on the phone can open our scheme, so
/// `tidynote://record` on its own is an instruction to start the microphone
/// that we did not write.
///
/// The widget and the control read the token out of the App Group, which only
/// this app's targets can open, and put it in the URL they build. The app
/// checks it on the way in. A URL without the token still opens the app, so a
/// stale widget is a wasted tap rather than a broken one.
public enum QuickCaptureToken {
    private enum Key {
        static let current = "quickCapture.token"
        /// The token the last launch retired. Kept because a widget timeline
        /// refreshes when the system feels like it, not when we ask: without
        /// one rotation of grace a widget that had not reloaded yet would
        /// carry a token the app has already thrown away.
        static let previous = "quickCapture.previousToken"
    }

    /// The token a URL built right now should carry, or `nil` before the first
    /// rotation and on a build with no App Group.
    public static func current(defaults: UserDefaults? = AppGroup.defaults) -> String? {
        defaults?.string(forKey: Key.current)
    }

    /// Every token an arriving URL may carry — the current one and the one it
    /// replaced. Both are random UUIDs no other app can read, so accepting two
    /// costs nothing a third-party app can use.
    public static func accepted(defaults: UserDefaults? = AppGroup.defaults) -> [String] {
        [defaults?.string(forKey: Key.current), defaults?.string(forKey: Key.previous)]
            .compactMap { $0 }
    }

    /// Mints a fresh token and retires the old one. Called once per launch, so
    /// a token that somehow leaked is good for one more launch at most.
    @discardableResult
    public static func rotate(defaults: UserDefaults? = AppGroup.defaults) -> String {
        let token = UUID().uuidString
        if let previous = defaults?.string(forKey: Key.current) {
            defaults?.set(previous, forKey: Key.previous)
        }
        defaults?.set(token, forKey: Key.current)
        return token
    }
}
