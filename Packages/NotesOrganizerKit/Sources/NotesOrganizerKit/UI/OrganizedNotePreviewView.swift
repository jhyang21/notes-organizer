import SwiftUI

/// Shows an organized note the way it will look once saved: title, section
/// headings, bullets, and checkbox action items. Lives in the package so the
/// share extension (M6) shows the user exactly the same preview the app does.
///
/// Deliberately plain — system fonts, system spacing, no chrome. The note is
/// the content; anything decorative here would be competing with it.
public struct OrganizedNotePreviewView: View {
    private let note: OrganizedNote

    public init(note: OrganizedNote) {
        self.note = note
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(note.title.isEmpty ? "Untitled note" : note.title)
                    .font(.title2.bold())
                    .foregroundStyle(note.title.isEmpty ? .secondary : .primary)

                ForEach(Array(note.sections.enumerated()), id: \.offset) { _, section in
                    sectionView(section)
                }

                if !note.actionItems.isEmpty {
                    actionItemsView
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
    }

    private func sectionView(_ section: NoteSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !section.heading.isEmpty {
                Text(section.heading)
                    .font(.headline)
            }
            ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                bulletRow(marker: "•", text: bullet)
            }
        }
    }

    private var actionItemsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Action Items")
                .font(.headline)
            ForEach(Array(note.actionItems.enumerated()), id: \.offset) { _, item in
                bulletRow(marker: "☐", text: item)
            }
        }
    }

    /// A leading marker on its own baseline so wrapped lines stay indented
    /// under the text, not under the bullet.
    private func bulletRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(.body)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    OrganizedNotePreviewView(note: OrganizedNote(
        title: "Dentist, Errands, and Sarah's Birthday",
        sections: [
            NoteSection(heading: "To Do", bullets: [
                "Call the dentist tomorrow to reschedule",
                "Pick up dry cleaning",
            ]),
            NoteSection(heading: "Sarah's Birthday", bullets: [
                "Sarah's birthday is next Friday",
                "Get her a gift — she likes candles",
            ]),
        ],
        actionItems: [
            "Call the dentist tomorrow to reschedule",
            "Pick up dry cleaning",
        ]
    ))
}
