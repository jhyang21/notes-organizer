import Foundation

/// The App Group the app and the share extension share. Anything that has to
/// look the same in both processes — the diagnostics log, a preference the
/// user shouldn't be asked about twice — reads and writes through this suite
/// rather than each target's own `UserDefaults`.
///
/// Must match the group in `App/App.entitlements` and
/// `ShareExtension/ShareExtension.entitlements`.
public enum AppGroup {
    public static let identifier = "group.com.immform.notesorganizer"

    /// `nil` on a build without the group entitlement — a simulator build,
    /// typically. Callers treat that as "no shared storage", not an error.
    public static var defaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    /// The group's shared directory, or `nil` on the same builds `defaults` is
    /// `nil` on. Anything the user typed belongs in a file here rather than in
    /// the suite above: a defaults plist is written without a data-protection
    /// class, so it can be read off a locked phone.
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
