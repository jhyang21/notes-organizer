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
        // `done` is a checklist's state and nothing else's. Anywhere else a
        // true would draw a tick the section has no boxes for.
        let keepsDone = section.kind == .checklist

        let items: [NoteItem] = section.items.compactMap { item in
            // Verbatim text is kept byte for byte: its spacing is the reason
            // the server marked it verbatim.
            let text = section.kind == .verbatim ? item.text : TextShaping.collapseWhitespace(item.text)
            guard !text.isEmpty else { return nil }
            return NoteItem(text: text, done: keepsDone && item.done)
        }

        guard !items.isEmpty else { return nil }
        return NoteSection(heading: heading, kind: section.kind, items: items)
    }
}
