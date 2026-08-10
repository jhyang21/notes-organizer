import Foundation

/// The near-empty guard applied before a transcript costs anyone a round trip
/// or a tidy. Kept apart from the organizer that calls it so "there was
/// nothing to organize" is one rule, stated once, and testable without a
/// network.
enum MeaningfulText {
    /// Below this many letters and digits there is nothing worth organizing;
    /// a model would invent structure around a stray word.
    static let minimumCharacters = 10

    static func isWorthOrganizing(_ text: String) -> Bool {
        let count = text.unicodeScalars.lazy.filter { CharacterSet.alphanumerics.contains($0) }.count
        return count >= minimumCharacters
    }
}
