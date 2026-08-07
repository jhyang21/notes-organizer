import Foundation

/// Renders an `OrganizedNote` to plain text for the clipboard-copy save
/// path. Output is exact and stable: same note in, same string out, every
/// time.
///
/// Layout: the title, then for each section a blank line followed by its
/// `HEADING` line (omitted when the heading is empty) and its `• bullet`
/// lines, then — if there are any — a blank line, `ACTION ITEMS`, and
/// `☐ item` lines.
public enum PlainTextRenderer {
    public static func render(_ note: OrganizedNote) -> String {
        var lines: [String] = [note.title]

        for section in note.sections {
            lines.append("")
            if !section.heading.isEmpty {
                lines.append(section.heading.uppercased())
            }
            for bullet in section.bullets {
                lines.append("• \(bullet)")
            }
        }

        if !note.actionItems.isEmpty {
            lines.append("")
            lines.append("ACTION ITEMS")
            for item in note.actionItems {
                lines.append("☐ \(item)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
