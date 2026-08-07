import Foundation

/// Renders an `OrganizedNote` to Markdown for the "share a `.md` file to
/// Notes" save path. Output is exact and stable: same note in, same string
/// out, every time.
///
/// Layout: `# Title`, then for each section a blank line followed by
/// `## Heading` (omitted when the heading is empty) and its `- bullet`
/// lines, then — if there are any — a blank line, `## Action Items`, and
/// `- [ ] item` lines.
public enum MarkdownRenderer {
    public static func render(_ note: OrganizedNote) -> String {
        var lines: [String] = ["# \(note.title)"]

        for section in note.sections {
            lines.append("")
            if !section.heading.isEmpty {
                lines.append("## \(section.heading)")
            }
            for bullet in section.bullets {
                lines.append("- \(bullet)")
            }
        }

        if !note.actionItems.isEmpty {
            lines.append("")
            lines.append("## Action Items")
            for item in note.actionItems {
                lines.append("- [ ] \(item)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
