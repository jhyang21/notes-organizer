import NotesOrganizerKit
import SwiftUI

/// The share extension's whole UI: loading → organizing → preview, with the
/// package's `OrganizedNotePreviewView`, `SaveActionsBar`, and
/// `UnavailableView` doing the work, so a note looks the same here as in the
/// app.
///
/// Cancel is always on screen: whatever else happens, the user can leave.
/// Done waits until there is something to be done with — it dismisses the
/// extension, and dismissing it mid-tidy would throw away work in flight
/// without saying so.
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
                .navigationTitle("TidyNote")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                            .disabled(isWorkInFlight)
                    }
                }
        }
        .animation(.default, value: model.state)
        .task {
            await model.start(with: items)
        }
        // A VoiceOver user working through the share sheet can't see the
        // preview arrive on its own.
        .onChange(of: model.state) { _, state in
            if case .preview = state {
                AccessibilityNotification.Announcement("Note ready.").post()
            }
        }
    }

    /// The two states with a call still running behind them.
    private var isWorkInFlight: Bool {
        switch model.state {
        case .loading, .organizing: true
        default: false
        }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            statusView(message: "Reading what you shared…")

        case .organizing(let wordCount):
            statusView(message: "Organizing ^[\(wordCount) words](inflect: true)…")

        case .preview(let note):
            previewView(note: note)

        case .nothingToOrganize:
            // Same title and sentence shape as the app's own "nothing to
            // work with" dead ends (`CaptureFailure.emptyRecording`,
            // `OrganizeFailure.emptyTranscript`) — a text-family symbol
            // instead of the voice ones, since nothing was even sent yet.
            NoticeView(
                symbol: "doc.slash",
                title: String(localized: "Nothing to tidy"),
                message: String(localized: "There's no text to organize. Select some text and share it again.")
            )

        case .unavailable(let failure):
            VStack(spacing: 16) {
                UnavailableView(
                    failure: failure,
                    onRetry: { Task { await model.retry() } },
                    // No paywall here — StoreKit's purchase UI doesn't work
                    // in a share extension, so `inShareExtension` turns the
                    // buttons only the app can honour into a line saying so.
                    inShareExtension: true
                )
                copyOriginalButton
            }
        }
    }

    private func statusView(message: LocalizedStringKey) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        // The spinner and its caption are one wait, not two things to swipe
        // past separately.
        .accessibilityElement(children: .combine)
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
            Button("Copy Original Text") {
                model.copyOriginalText()
            }
            .buttonStyle(.bordered)
        }
    }
}

#Preview("Preview state") {
    ShareRootView(
        items: [],
        model: ShareViewModel(routing: OrganizeRouting(
            cloud: MockOrganizer(result: OrganizedNote(
                title: "Kitchen Renovation Notes",
                sections: [NoteSection(heading: "Quotes", bullets: ["Bosch quoted 4,200 for cabinets"])],
                actionItems: ["Call the contractor back on Thursday"]
            ))
        )),
        onDone: {},
        onCancel: {}
    )
}
