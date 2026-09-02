import Foundation

/// Renders an `OrganizedNote` to plain text for the clipboard-copy save
/// path. Output is exact and stable: same note in, same string out, every
/// time.
///
/// Layout: the title, then the summary after a blank line when there is one,
/// then for each section a blank line, its `HEADING` line (omitted when the
/// heading is empty), and its items marked according to the section's kind.
/// There is no trailing newline — the string is lines joined, not lines
/// terminated, so pasting it adds nothing the user didn't ask for.
public enum PlainTextRenderer {
    public static func render(_ note: OrganizedNote) -> String {
        var lines: [String] = [note.title]

        if !note.summary.isEmpty {
            lines.append("")
            lines.append(note.summary)
        }

        for section in note.sections {
            lines.append("")
            if !section.heading.isEmpty {
                lines.append(section.heading.uppercased())
            }
            lines.append(contentsOf: itemLines(of: section))
        }

        return lines.joined(separator: "\n")
    }

    /// The items of one section, already marked. Numbering restarts in every
    /// section, because a number is an index into that section's procedure,
    /// not into the note.
    private static func itemLines(of section: NoteSection) -> [String] {
        switch section.kind {
        case .bullets:
            return section.items.map { "• \($0.text)" }
        case .checklist:
            return section.items.map { "\($0.done ? "☑" : "☐") \($0.text)" }
        case .numbered:
            return section.items.enumerated().map { "\($0.offset + 1). \($0.element.text)" }
        case .paragraph:
            // Prose reads as prose: no marker, and a blank line between
            // paragraphs so they don't run together. The heading still sits
            // directly above the first one, the same as every other kind.
            return Array(section.items.flatMap { [$0.text, ""] }.dropLast())
        case .verbatim:
            // Reproduced exactly — no marker, no trimming. Whatever spacing
            // the text carries is the point of asking for it.
            return section.items.map(\.text)
        }
    }
}
