import Foundation

/// What a capture's audio file is called, and when a leftover one has
/// outstayed its welcome. Naming and expiry are the only parts of the file's
/// life that can be decided without a disk, so they live here where they can
/// be tested; the app does the writing and the deleting.
///
/// Recordings sit in the process's own temporary directory and never in the
/// App Group: the share extension has no use for one, and a directory the
/// system can empty on its own is exactly the right home for a file that
/// exists only until the note comes back.
public struct RecordingFile: Equatable, Sendable {
    /// The prefix that tells TidyNote's leftovers apart from everything else
    /// sharing the temporary directory. A sweep deletes what it recognizes and
    /// nothing else.
    public static let namePrefix = "capture-"

    public static let pathExtension = "m4a"

    /// How long a leftover may sit before a launch sweeps it. A day is long
    /// enough that a tidy interrupted by a crash or a dead battery still has
    /// its recording when the user comes back to it, and short enough that
    /// nothing of theirs lingers on the phone.
    public static let maximumAge: TimeInterval = 24 * 60 * 60

    /// A name for a recording about to be made. Random, because two captures
    /// in the same second must not land on the same file.
    public static func newName(id: UUID = UUID()) -> String {
        "\(namePrefix)\(id.uuidString).\(pathExtension)"
    }

    /// Whether a file found in the temporary directory is one of ours.
    public static func isRecording(_ name: String) -> Bool {
        name.hasPrefix(namePrefix) && name.hasSuffix(".\(pathExtension)")
    }

    /// Which of the files a launch found should be deleted: ours, and older
    /// than `maximumAge`. A file dated in the future — a clock that moved
    /// backwards — is left alone rather than treated as ancient, since the
    /// only thing wrong with it is the timestamp.
    public static func stale(
        among files: [RecordingFile],
        now: Date,
        maximumAge: TimeInterval = RecordingFile.maximumAge
    ) -> [RecordingFile] {
        files.filter { file in
            isRecording(file.name) && now.timeIntervalSince(file.modifiedAt) > maximumAge
        }
    }

    public let name: String
    public let modifiedAt: Date

    public init(name: String, modifiedAt: Date) {
        self.name = name
        self.modifiedAt = modifiedAt
    }
}
