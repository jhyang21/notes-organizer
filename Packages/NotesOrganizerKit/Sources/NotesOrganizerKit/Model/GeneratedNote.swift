#if canImport(FoundationModels)
import FoundationModels

/// Guided-generation mirror of `OrganizedNote`. The model only ever produces
/// values of this shape — `OrganizedNote.init(_:)` converts a result into
/// the plain domain model the rest of the app works with. Kept internal:
/// callers outside this package only ever see `OrganizedNote`.
///
/// This file must compile wherever the iOS 26 SDK is available (CI's
/// simulator included), but nothing in the unit test suite may construct or
/// run the actual model — CI simulators have no Apple Intelligence model.
@Generable
struct GeneratedNote {
    @Guide(description: "A short, specific title for the note, 3 to 8 words. Never a generic title like 'Notes' or 'Untitled'.")
    var title: String

    @Guide(description: "Sections grouping related bullets, in the order the ideas appeared in the input. A single section with an empty heading is fine when the input is one short thought with no natural grouping.")
    var sections: [GeneratedSection]

    @Guide(description: "Explicit self-directed action items the speaker stated they need to do. Empty when the input names no clear personal task.")
    var actionItems: [String]
}

/// Guided-generation mirror of `NoteSection`.
@Generable
struct GeneratedSection {
    @Guide(description: "A short heading, 1 to 4 words, or an empty string when the bullets below don't warrant a heading of their own.")
    var heading: String

    @Guide(description: "Bullet points that preserve every fact, name, number, and date from this part of the input, reworded only to drop filler words.")
    var bullets: [String]
}

/// Guided-generation output for the chunk-merge title refinement pass: given
/// several chunk titles, the model picks or writes one title for the note
/// as a whole. Used by the (M5) merge step, not by `TranscriptChunker` or
/// `NoteMerger` themselves, which are pure and model-free.
@Generable
struct NoteTitle {
    @Guide(description: "A short, specific title, 3 to 8 words, describing the note as a whole.")
    var title: String
}

extension OrganizedNote {
    /// Maps a model result into the plain domain model. Sanitizing and the
    /// over-summarization check happen separately, in `OutputSanitizer`.
    init(_ generated: GeneratedNote) {
        self.init(
            title: generated.title,
            sections: generated.sections.map { NoteSection(heading: $0.heading, bullets: $0.bullets) },
            actionItems: generated.actionItems
        )
    }
}
#endif
