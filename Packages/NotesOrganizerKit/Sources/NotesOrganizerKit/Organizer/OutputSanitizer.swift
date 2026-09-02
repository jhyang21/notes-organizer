import Foundation

/// Cleans up an `OrganizedNote` on its way back from the model: collapsed
/// whitespace, no blank items, no empty sections, no runaway headings. Pure
/// and deterministic — no model calls.
///
/// Structural only. The server is authoritative about what a note says: it
/// decides the wording, the order, the section kinds, and which lines are
/// repeats worth dropping. This pass exists so the renderer and the preview
/// are never handed a blank line or a heading the width of the screen, not
/// to second-guess the tidy.
enum OutputSanitizer {
    static let maxHeadingLength = 60

    static func sanitize(_ note: OrganizedNote) -> OrganizedNote {
        OrganizedNote(
            title: TextShaping.collapseWhitespace(note.title),
            summary: TextShaping.collapseWhitespace(note.summary),
            sections: note.sections.compactMap(sanitize(section:))
        )
    }

    /// Drops the section entirely once it has no items left, so a section
    /// with no content never reaches the renderer.
    private static func sanitize(section: NoteSection) -> NoteSection? {
        let heading = TextShaping.truncate(TextShaping.collapseWhitespace(section.heading), to: maxHeadingLength)
        let items = section.kind == .verbatim
            ? verbatimItems(section.items)
            : shapedItems(section.items, kind: section.kind)

        guard !items.isEmpty else { return nil }
        return NoteSection(heading: heading, kind: section.kind, items: items)
    }

    /// Verbatim text is kept character for character: its spacing is the
    /// reason the server marked it verbatim. Only the blank items at either
    /// end go — a blank line inside a code block or a pasted quote belongs
    /// to the block, it isn't padding around it. The server trims the same
    /// two ends.
    private static func verbatimItems(_ items: [NoteItem]) -> [NoteItem] {
        guard let first = items.firstIndex(where: { !isBlank($0.text) }),
              let last = items.lastIndex(where: { !isBlank($0.text) })
        else { return [] }

        return items[first...last].map { NoteItem(text: $0.text, done: false) }
    }

    /// Every other kind, where a blank item is nothing and goes.
    private static func shapedItems(_ items: [NoteItem], kind: SectionKind) -> [NoteItem] {
        // `done` is a checklist's state and nothing else's. Anywhere else a
        // true would draw a tick the section has no boxes for.
        let keepsDone = kind == .checklist

        return items.compactMap { item in
            // A paragraph may run to several lines — a sign-off, an address —
            // and those breaks are the writing. A bullet, a task or a step is
            // one line by definition, so it collapses whole.
            let text = kind == .paragraph
                ? TextShaping.collapseLines(item.text)
                : TextShaping.collapseWhitespace(item.text)
            guard !text.isEmpty else { return nil }
            return NoteItem(text: text, done: keepsDone && item.done)
        }
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
