import NotesOrganizerKit
import SwiftUI

/// The share extension's whole UI: loading → organizing → preview, with the
/// package's `OrganizedNotePreviewView`, `SaveActionsBar`, and
/// `UnavailableView` doing the work, so a note looks the same here as in the
/// app.
///
/// Cancel and Done are always on screen. Whatever else happens, the user can
/// close the extension.
struct ShareRootView: View {
    @State private var model: ShareViewModel

    private let items: [NSExtensionItem]
    private let onDone: () -> Void
    private let onCancel: () -> Void

    init(
        items: [NSExtensionItem],
        model: ShareViewModel = ShareViewModel(),
        onDone: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.items = items
        _model = State(initialValue: model)
        self.onDone = onDone
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            content
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Notes Organizer")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
        }
        .animation(.default, value: model.state)
        .task {
            await model.start(with: items)
        }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            statusView(message: "Reading what you shared…")

        case .organizing(let wordCount):
            statusView(message: "Organizing \(wordCount) words…")

        case .preview(let note):
            previewView(note: note)

        case .nothingToOrganize:
            NoticeView(
                symbol: "doc.text",
                title: "There's no text here",
                message: "Select the text you want organized, then share it again."
            )

        case .unavailable(let failure):
            VStack(spacing: 16) {
                UnavailableView(failure: failure) {
                    Task { await model.retry() }
                }
                copyOriginalButton
            }
        }
    }

    private func statusView(message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func previewView(note: OrganizedNote) -> some View {
        VStack(spacing: 16) {
            OrganizedNotePreviewView(note: note)
                .frame(maxHeight: .infinity)

            SaveActionsBar(note: note, source: .shareExtension)
        }
    }

    /// The one path that works no matter what the model did: the text the
    /// user shared, back on the clipboard.
    @ViewBuilder
    private var copyOriginalButton: some View {
        if !model.originalText.isEmpty {
            Button("Copy original text") {
                model.copyOriginalText()
            }
            .buttonStyle(.bordered)
        }
    }
}

#Preview("Preview state") {
    ShareRootView(
        items: [],
        model: ShareViewModel(organizer: MockOrganizer(result: OrganizedNote(
            title: "Kitchen Renovation Notes",
            sections: [NoteSection(heading: "Quotes", bullets: ["Bosch quoted 4,200 for cabinets"])],
            actionItems: ["Call the contractor back on Thursday"]
        ))),
        onDone: {},
        onCancel: {}
    )
}
