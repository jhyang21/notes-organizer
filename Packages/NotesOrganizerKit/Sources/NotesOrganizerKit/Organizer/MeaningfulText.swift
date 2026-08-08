import Foundation

/// The near-empty guard both organizers apply before spending anything on a
/// transcript. Shared rather than copied so "there was nothing to organize"
/// means the same thing on-device and in the cloud — a user who gets
/// `.emptyTranscript` from one would be confused to get a note from the other.
enum MeaningfulText {
    /// Below this many letters and digits there is nothing worth organizing;
    /// a model would invent structure around a stray word.
    static let minimumCharacters = 10

    static func isWorthOrganizing(_ text: String) -> Bool {
        let count = text.unicodeScalars.lazy.filter { CharacterSet.alphanumerics.contains($0) }.count
        return count >= minimumCharacters
    }
}
