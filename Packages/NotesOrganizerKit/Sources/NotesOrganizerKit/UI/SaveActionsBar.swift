import SwiftUI
import UIKit

/// The two ways out of a finished note.
///
/// 1. **Save to Apple Notes** — shares the note as plain text. Notes' share
///    row takes text straight into a new note, so the save is one step and
///    it works. The bar used to share a `.md` file instead, on the theory
///    that Notes imports Markdown as rich text; the device test on
///    2026-08-11 showed that path saving nothing at all, and the extra
///    Import screen went with it. Headings and checkboxes now arrive as
///    text lines.
/// 2. **Copy as text** — the clipboard, for pasting into anything.
///
/// Uses `ShareLink` rather than wrapping `UIActivityViewController`: same
/// sheet, no `UIViewControllerRepresentable`, and it stays extension-safe.
public struct SaveActionsBar: View {
    /// Which way out the user took. Recorded because once the share sheet
    /// takes over there is no other way to know which one they picked — and
    /// in the extension, no way to know it opened at all.
    public enum Action: String, Sendable {
        case saveToNotes
        case copyAsText
    }

    private let note: OrganizedNote
    private let plainText: String
    private let source: DiagnosticsSource
    private let log: DiagnosticsLog

    @State private var showCopiedConfirmation = false

    public init(note: OrganizedNote, source: DiagnosticsSource, log: DiagnosticsLog = .shared) {
        self.note = note
        self.plainText = PlainTextRenderer.render(note)
        self.source = source
        self.log = log
    }

    public var body: some View {
        VStack(spacing: 12) {
            saveToNotes
            copyAsTextButton
        }
    }

    // MARK: - Save to Apple Notes

    private var saveToNotes: some View {
        ShareLink(item: plainText, subject: Text(note.title)) {
            Label("Save to Apple Notes", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .simultaneousGesture(TapGesture().onEnded {
            record(.saveToNotes)
        })
    }

    // MARK: - Copy as text

    private var copyAsTextButton: some View {
        Button {
            copyAsText()
        } label: {
            Label(
                showCopiedConfirmation ? "Copied" : "Copy as text",
                systemImage: showCopiedConfirmation ? "checkmark" : "doc.on.doc"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Actions

    private func copyAsText() {
        UIPasteboard.general.string = plainText
        record(.copyAsText)
        showCopiedConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showCopiedConfirmation = false
        }
    }

    private func record(_ action: Action) {
        log.recordEvent(source: source, message: "Save action: \(action.rawValue)")
    }
}

#Preview {
    SaveActionsBar(
        note: OrganizedNote(
            title: "Kitchen Renovation Notes",
            sections: [NoteSection(heading: "Quotes", bullets: ["Bosch quoted 4,200 for cabinets"])],
            actionItems: ["Call the contractor back on Thursday"]
        ),
        source: .app
    )
    .padding()
}
