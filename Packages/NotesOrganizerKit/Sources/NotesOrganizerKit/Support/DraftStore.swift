import Foundation

/// The one note the app is still holding: whatever is on the preview screen,
/// kept so a finished tidy survives the app being swiped away. A single slot,
/// not a library — Apple Notes is where notes live, and this is only the
/// hand-off that hasn't happened yet.
///
/// A finished note is a spent tidy. Losing it to a swipe up costs the user the
/// tidy as well as the screen, which is the whole reason this exists.
///
/// The slot is a file in the App Group container rather than a defaults key.
/// The note is the user's own words, and a defaults plist is written with no
/// data-protection class at all — readable off a locked phone by anything that
/// can reach the disk. The file is written `.completeFileProtectionUnlessOpen`
/// and kept out of backups, so a spent tidy waiting to be sent is unreadable
/// while the phone is locked and never leaves the device in an iCloud backup.
/// "Unless open" rather than "complete" because the note can arrive while the
/// phone is locked, and a class that refuses the write there would drop the
/// one copy this slot exists to keep.
///
/// The app owns the slot alone. The share extension never writes here, so an
/// extension tidy can't overwrite the note the user left on screen in the app.
///
/// Best effort in the same way `EntitlementStore` is — a build without the
/// group entitlement gets `nil` defaults and no directory, every write goes
/// nowhere, and the user loses a restored draft rather than a note.
public struct DraftStore: @unchecked Sendable {
    // `UserDefaults` is thread-safe but not `Sendable`; same trade as
    // `EntitlementStore`.
    private let defaults: UserDefaults?
    /// Where the note file lives, or `nil` to fall back to `defaults`. Unit
    /// tests hand over a temporary directory; a build with no App Group has
    /// neither and keeps the old behaviour rather than crashing.
    private let directory: URL?

    /// The instance the app uses.
    public static let shared = DraftStore(
        defaults: AppGroup.defaults,
        directory: DraftStore.sharedDirectory
    )

    /// `Library/` rather than the container root: it is the part of an app
    /// group the system already treats as private support data.
    private static var sharedDirectory: URL? {
        AppGroup.containerURL?.appending(path: "Library/Draft")
    }

    private static let fileName = "organizedNote.v2.json"

    private enum Key {
        static let note = "draft.organizedNote.v2"
        /// The slot as it was before sections gained kinds and items.
        static let legacyNote = "draft.organizedNote"
    }

    public init(defaults: UserDefaults?, directory: URL? = nil) {
        self.defaults = defaults
        self.directory = directory
    }

    private var fileURL: URL? {
        directory?.appending(path: Self.fileName)
    }

    public func save(_ note: OrganizedNote) {
        guard let data = try? JSONEncoder().encode(note) else { return }
        guard var url = fileURL else {
            defaults?.set(data, forKey: Key.note)
            return
        }

        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            return
        }

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// The saved note, or `nil` when there isn't one — including when what is
    /// stored no longer decodes. Either way the answer is "nothing to
    /// restore".
    ///
    /// Also where the two old slots are swept up. A pre-v2 draft would decode
    /// into a note with no sections, so it is deleted rather than read: the
    /// user gets an empty screen instead of a gutted note. A v2 draft still in
    /// defaults is one this version moved to a file, so it is read once, put
    /// in the file, and taken out of the plist it should never have been in.
    public func load() -> OrganizedNote? {
        defaults?.removeObject(forKey: Key.legacyNote)

        guard let url = fileURL else {
            guard let data = defaults?.data(forKey: Key.note) else { return nil }
            return try? JSONDecoder().decode(OrganizedNote.self, from: data)
        }

        if let data = try? Data(contentsOf: url) {
            return try? JSONDecoder().decode(OrganizedNote.self, from: data)
        }

        guard let data = defaults?.data(forKey: Key.note) else { return nil }
        defaults?.removeObject(forKey: Key.note)
        guard let note = try? JSONDecoder().decode(OrganizedNote.self, from: data) else { return nil }
        save(note)
        return note
    }

    public func clear() {
        defaults?.removeObject(forKey: Key.note)
        defaults?.removeObject(forKey: Key.legacyNote)
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
