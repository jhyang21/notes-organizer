import Foundation

/// Cleans up an `OrganizedNote` on its way back from the model: collapsed
/// whitespace, no blank bullets, no repeated lines, no runaway headings. Pure
/// and deterministic — no model calls.
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
}
