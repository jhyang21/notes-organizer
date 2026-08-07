import Foundation

/// Writes a note to a temporary `.md` file for the share sheet. This is the
/// primary save path: iOS 26 Notes imports a Markdown *file* as real rich
/// text, so the user taps Notes → Import and gets a formatted note. There is
/// no Notes write API; a file is the closest thing to one.
///
/// The filename is the note's title, because that is what Notes uses to name
/// the imported note.
public enum NoteShareItem {
    /// Files older than this are swept on the next `removeStaleFiles` call.
    /// An hour is far longer than any share sheet stays open, and short
    /// enough that a user's notes don't linger on disk.
    public static let staleAfter: TimeInterval = 3600

    /// A subdirectory of the temp directory, so cleanup can sweep it without
    /// touching anything else the system put in `tmp`.
    public static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OrganizedNotes", isDirectory: true)
    }

    /// Writes `note` as Markdown and returns the file URL to hand to the
    /// share sheet. Overwrites any earlier file with the same title, so
    /// re-sharing the same note doesn't pile up copies.
    @discardableResult
    public static func makeMarkdownFile(for note: OrganizedNote, in directory: URL = NoteShareItem.defaultDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory
            .appendingPathComponent(NoteFilename.sanitize(note.title), isDirectory: false)
            .appendingPathExtension("md")

        try MarkdownRenderer.render(note).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Deletes files left behind by earlier shares. Best effort: a file that
    /// won't delete is skipped rather than failing the caller, since this
    /// only ever runs as housekeeping alongside real work.
    public static func removeStaleFiles(
        olderThan age: TimeInterval = NoteShareItem.staleAfter,
        in directory: URL = NoteShareItem.defaultDirectory
    ) {
        let manager = FileManager.default
        guard let contents = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-age)
        for url in contents {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? manager.removeItem(at: url)
        }
    }
}
