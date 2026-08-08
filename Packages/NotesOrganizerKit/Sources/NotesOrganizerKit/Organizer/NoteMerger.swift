import Foundation

/// Recombines the per-chunk `OrganizedNote`s from `TranscriptChunker` back
/// into one note. Pure and deterministic — no model calls.
enum NoteMerger {
    /// The title falls back to the first chunk with a non-empty title. The
    /// model-based title refinement pass belongs to the caller, not to this
    /// merge step.
    static func merge(_ notes: [OrganizedNote]) -> OrganizedNote {
        guard !notes.isEmpty else { return OrganizedNote() }

        let title = notes.first { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.title ?? ""

        return OrganizedNote(
            title: title,
            sections: mergeSections(notes.flatMap(\.sections)),
            actionItems: dedupeActionItems(notes.flatMap(\.actionItems))
        )
    }

    /// Merges only sections that are directly adjacent in the flattened
    /// order and share a heading (case-insensitive, trimmed) — this keeps
    /// each chunk's own ordering intact rather than grouping same-named
    /// headings from anywhere in the note.
    private static func mergeSections(_ sections: [NoteSection]) -> [NoteSection] {
        var merged: [NoteSection] = []
        for section in sections {
            if let lastIndex = merged.indices.last, headingsMatch(merged[lastIndex].heading, section.heading) {
                merged[lastIndex].bullets.append(contentsOf: section.bullets)
            } else {
                merged.append(section)
            }
        }
        return merged
    }

    private static func headingsMatch(_ a: String, _ b: String) -> Bool {
        normalized(a) == normalized(b)
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func dedupeActionItems(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            let key = normalized(item)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(item)
        }
        return result
    }
}
