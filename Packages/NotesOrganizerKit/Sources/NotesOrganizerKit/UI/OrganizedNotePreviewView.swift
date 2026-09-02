import SwiftUI

/// Shows an organized note the way it will look once saved: title, summary,
/// and a block per section drawn the way its kind reads — prose, bullets,
/// checkboxes, a numbered procedure, or text reproduced exactly. Lives in the
/// package so the share extension shows the user exactly the same preview the
/// app does.
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
                Text(note.title.isEmpty ? String(localized: "Untitled note", bundle: .module) : note.title)
                    .font(.title2.bold())
                    .foregroundStyle(note.title.isEmpty ? .secondary : .primary)
                    .accessibilityAddTraits(.isHeader)

                if !note.summary.isEmpty {
                    Text(note.summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(note.sections.enumerated()), id: \.offset) { _, section in
                    sectionView(section)
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
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                itemView(item, at: index, kind: section.kind)
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: NoteItem, at index: Int, kind: SectionKind) -> some View {
        switch kind {
        case .bullets:
            markedRow(text: item.text) {
                Text(verbatim: "•")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        case .checklist:
            markedRow(text: item.text, label: checkboxLabel(done: item.done)) {
                Image(systemName: item.done ? "checkmark.square" : "square")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        case .numbered:
            markedRow(text: item.text) {
                Text(verbatim: "\(index + 1).")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .paragraph:
            Text(item.text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .verbatim:
            Text(item.text)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// VoiceOver reads a checkbox as a word, not as a picture: the state
    /// comes first, then the item, so a list of them can be skimmed.
    private func checkboxLabel(done: Bool) -> String {
        done
            ? String(localized: "Completed", bundle: .module)
            : String(localized: "Not completed", bundle: .module)
    }

    /// A leading marker on its own baseline so wrapped lines stay indented
    /// under the text, not under the marker.
    private func markedRow(
        text: String,
        label: String? = nil,
        @ViewBuilder marker: () -> some View
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker()
            Text(text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label.map { "\($0), \(text)" } ?? text)
    }
}

#Preview {
    OrganizedNotePreviewView(note: OrganizedNote(
        title: "Kitchen Renovation",
        summary: "We compared two cabinet quotes and settled the timeline.",
        sections: [
            NoteSection(heading: "Quotes", kind: .bullets, items: [
                "Bosch quoted 4,200 for cabinets",
            ]),
            NoteSection(heading: "To Do", kind: .checklist, items: [
                NoteItem(text: "Call the contractor back on Thursday"),
                NoteItem(text: "Send Priya the floor plan", done: true),
            ]),
            NoteSection(heading: "Install Steps", kind: .numbered, items: [
                "Remove the old units",
                "Level the floor",
            ]),
            NoteSection(heading: "Contractor Wi-Fi", kind: .verbatim, items: [
                "SSID: Site-Office",
                "Pass:  x7 Q!9",
            ]),
        ]
    ))
}
