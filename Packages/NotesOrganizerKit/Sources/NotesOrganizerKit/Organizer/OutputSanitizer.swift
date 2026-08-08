import Foundation

/// Cleans up a model (or merged) `OrganizedNote` and flags output that
/// looks summarized rather than organized. Pure and deterministic — no
/// model calls.
enum OutputSanitizer {
    static let maxHeadingLength = 60

    static func sanitize(_ note: OrganizedNote) -> OrganizedNote {
        let sections = note.sections.compactMap(sanitize(section:))

        var seen = Set<String>()
        var actionItems: [String] = []
        for rawItem in note.actionItems {
            let item = TextShaping.collapseWhitespace(rawItem)
            let key = item.lowercased()
            guard !item.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            actionItems.append(item)
        }

        return OrganizedNote(title: TextShaping.collapseWhitespace(note.title), sections: sections, actionItems: actionItems)
    }

    /// Drops the section entirely once its bullets are all empty/duplicate,
    /// so a section with no remaining content never reaches the renderer.
    private static func sanitize(section: NoteSection) -> NoteSection? {
        let heading = TextShaping.truncate(TextShaping.collapseWhitespace(section.heading), to: maxHeadingLength)

        var bullets: [String] = []
        var previousKey: String?
        for rawBullet in section.bullets {
            let bullet = TextShaping.collapseWhitespace(rawBullet)
            guard !bullet.isEmpty else { continue }
            let key = bullet.lowercased()
            if key == previousKey { continue }
            bullets.append(bullet)
            previousKey = key
        }

        guard !bullets.isEmpty else { return nil }
        return NoteSection(heading: heading, bullets: bullets)
    }

    /// The plan's over-summarization guard: reorganizing a transcript
    /// should not shrink its word count by more than 60%. A word is a
    /// whitespace-separated token; the input side counts words in the raw
    /// transcript text, and the output side counts words across the note's
    /// title, section headings, bullets, and action items combined. This is
    /// a coarse heuristic, not a semantic check — it exists to catch a
    /// model that summarized instead of organized, not to validate content.
    static func isOverSummarized(input: String, output: OrganizedNote) -> Bool {
        let inputWordCount = WordCounter.count(input)
        guard inputWordCount > 0 else { return false }

        let outputText = ([output.title] + output.sections.flatMap { [$0.heading] + $0.bullets } + output.actionItems)
            .joined(separator: " ")
        let outputWordCount = WordCounter.count(outputText)

        return Double(outputWordCount) < Double(inputWordCount) * 0.6
    }
}
