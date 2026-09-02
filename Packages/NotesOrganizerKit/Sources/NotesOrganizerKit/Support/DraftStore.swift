import Foundation

/// The one note the app is still holding: whatever is on the preview screen,
/// kept so a finished tidy survives the app being swiped away. A single slot,
/// not a library — Apple Notes is where notes live, and this is only the
/// hand-off that hasn't happened yet.
///
/// A finished note is a spent tidy. Losing it to a swipe up costs the user the
/// tidy as well as the screen, which is the whole reason this exists.
///
/// The app owns the slot alone. The share extension never writes here, so an
/// extension tidy can't overwrite the note the user left on screen in the app.
///
/// Best effort in the same way `EntitlementStore` is — a build without the
/// group entitlement gets `nil` defaults, every write goes nowhere, and the
/// user loses a restored draft rather than a note.
public struct DraftStore: @unchecked Sendable {
    // `UserDefaults` is thread-safe but not `Sendable`; same trade as
    // `EntitlementStore`.
    private let defaults: UserDefaults?

    /// The instance the app uses.
    public static let shared = DraftStore(defaults: AppGroup.defaults)

    private enum Key {
        static let note = "draft.organizedNote.v2"
        /// The slot as it was before sections gained kinds and items.
        static let legacyNote = "draft.organizedNote"
    }

    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    public func save(_ note: OrganizedNote) {
        guard let data = try? JSONEncoder().encode(note) else { return }
        defaults?.set(data, forKey: Key.note)
    }

    /// The saved note, or `nil` when there isn't one — including when what is
    /// stored no longer decodes. Either way the answer is "nothing to
    /// restore".
    ///
    /// Also the one place the pre-v2 slot is swept up. An old-shape draft
    /// would decode into a note with no sections, so it is deleted rather
    /// than read: the user gets an empty screen instead of a gutted note,
    /// and the bytes don't sit in the App Group forever.
    public func load() -> OrganizedNote? {
        defaults?.removeObject(forKey: Key.legacyNote)
        guard let data = defaults?.data(forKey: Key.note) else { return nil }
        return try? JSONDecoder().decode(OrganizedNote.self, from: data)
    }

    public func clear() {
        defaults?.removeObject(forKey: Key.note)
    }
}
