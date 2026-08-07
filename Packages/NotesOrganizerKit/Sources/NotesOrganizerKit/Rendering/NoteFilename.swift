import Foundation

/// Turns a note title into a filename. Pure — the file writing itself lives
/// in `NoteShareItem`.
///
/// The name matters more than it looks: it is what Notes shows as the
/// imported note's title, and what the share sheet displays. So the goal is
/// a readable name, not an escaped one — hostile characters are replaced
/// with spaces rather than underscores or percent escapes.
enum NoteFilename {
    static let maxLength = 60
    static let fallbackName = "Note"

    /// Characters that break paths on Apple platforms, plus the ones that
    /// break on other systems the file might travel to.
    private static let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")

    static func sanitize(_ title: String) -> String {
        let replaced = String(String.UnicodeScalarView(title.unicodeScalars.map { scalar in
            forbidden.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) ? " " : scalar
        }))

        let collapsed = replaced
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // A leading dot would make a hidden file; trailing dots and spaces
        // are silently dropped by some filesystems.
        let trimmed = cap(collapsed).trimmingCharacters(in: CharacterSet(charactersIn: ". "))

        return trimmed.isEmpty ? fallbackName : trimmed
    }

    private static func cap(_ text: String) -> String {
        guard text.count > maxLength else { return text }

        let limit = text.index(text.startIndex, offsetBy: maxLength)
        let truncated = text[text.startIndex..<limit]
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[truncated.startIndex..<lastSpace])
        }
        return String(truncated)
    }
}
