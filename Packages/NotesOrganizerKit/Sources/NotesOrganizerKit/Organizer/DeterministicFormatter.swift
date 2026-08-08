import Foundation

/// The lossless fallback: turns raw text into an `OrganizedNote` without the
/// model. Pure and deterministic — no model calls, no rewording, nothing
/// dropped. Every word of the input survives into a bullet, which is the
/// whole point: when the model refuses a transcript or keeps summarizing it,
/// the user still gets their own words back with some shape on them.
///
/// Shape: each blank-line-separated paragraph becomes a section with an
/// empty heading; each sentence (or each line, for text that is already a
/// list) becomes a bullet. Action items are always empty — deciding what
/// counts as a task is exactly the judgement this formatter doesn't have.
enum DeterministicFormatter {
    static let maxTitleLength = 60

    static func format(_ text: String) -> OrganizedNote {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return OrganizedNote() }

        let sections = TextShaping.paragraphs(in: trimmed)
            .map { NoteSection(heading: "", bullets: bullets(in: $0)) }
            .filter { !$0.bullets.isEmpty }

        return OrganizedNote(title: title(from: trimmed), sections: sections)
    }

    // MARK: - Title

    /// The first line, cut back to its first sentence when that line is long,
    /// capped at `maxTitleLength` on a word boundary. The title is a label
    /// derived from the body, not a replacement for it — the same words stay
    /// in the first bullet, so nothing is lost by titling.
    private static func title(from text: String) -> String {
        let firstLine = text
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""

        var candidate = TextShaping.collapseWhitespace(firstLine)
        if let sentence = TextShaping.sentences(in: candidate).first {
            candidate = sentence
        }
        return trimTrailingPunctuation(TextShaping.truncate(candidate, to: maxTitleLength))
    }

    private static func trimTrailingPunctuation(_ text: String) -> String {
        var result = text
        while let last = result.last, last.isPunctuation || last.isWhitespace {
            result.removeLast()
        }
        return result
    }

    // MARK: - Body

    /// Text that already has line breaks is treated as a list — one bullet
    /// per line. Text on a single line is split into sentences instead.
    private static func bullets(in paragraph: String) -> [String] {
        let lines = paragraph
            .components(separatedBy: .newlines)
            .map { TextShaping.collapseWhitespace($0) }
            .filter { !$0.isEmpty }

        if lines.count > 1 {
            return lines
        }
        let single = lines.first ?? ""
        let sentenceList = TextShaping.sentences(in: single)
        return sentenceList.isEmpty ? (single.isEmpty ? [] : [single]) : sentenceList
    }
}
