import Foundation

/// The small text operations the sanitizer needs. One definition each, so a
/// note's title, its headings, and its items are cut and collapsed the same
/// way.
///
/// The length limits stay with their callers: each is an independent limit
/// that happens to agree with the others today.
enum TextShaping {
    /// Cuts `text` to `maxLength` characters at the last word boundary
    /// within that limit, rather than mid-word.
    static func truncate(_ text: String, to maxLength: Int) -> String {
        guard text.count > maxLength else { return text }

        let limit = text.index(text.startIndex, offsetBy: maxLength)
        let truncated = text[text.startIndex..<limit]
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[truncated.startIndex..<lastSpace])
        }
        return String(truncated)
    }

    /// Every run of whitespace — including newlines — becomes a single space.
    static func collapseWhitespace(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Like `collapseWhitespace`, but line breaks survive: every line is
    /// collapsed and trimmed on its own, blank lines are dropped, and what
    /// is left is rejoined with newlines. The result is empty only when
    /// every line was blank.
    ///
    /// For text where a break carries meaning — an email sign-off, an
    /// address — and reflowing it into one line loses that.
    static func collapseLines(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map(collapseWhitespace)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
