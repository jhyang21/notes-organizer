import Foundation

/// One definition of "a word" for the whole app: a whitespace-separated
/// token. Coarse on purpose — it feeds the over-summarization guard and the
/// diagnostics timings, neither of which needs linguistic accuracy, and both
/// of which would mislead if they counted differently from each other.
public enum WordCounter {
    public static func count(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// The words a note says: its title, its summary, its headings, and the
    /// text of every item. Counted on the note rather than on the rendered
    /// string so the bullets, checkboxes, and numbers a renderer adds are
    /// never counted as words the user said.
    public static func count(_ note: OrganizedNote) -> Int {
        var total = count(note.title) + count(note.summary)
        for section in note.sections {
            total += count(section.heading)
            for item in section.items {
                total += count(item.text)
            }
        }
        return total
    }
}
