import SwiftUI
import UIKit

/// The three ways out of a finished note, in order of how well they work.
///
/// 1. **Save to Apple Notes** — shares a `.md` file. Notes imports Markdown
///    files as real rich text, so headings and checkboxes survive. It costs
///    one extra tap ("Import"), which is why the hint below exists.
/// 2. **Copy as text** — the clipboard, for pasting into anything.
/// 3. **Share as text** — the share sheet with a plain string, for apps that
///    would rather have text than a file.
///
/// Uses `ShareLink` rather than wrapping `UIActivityViewController`: same
/// sheet, no `UIViewControllerRepresentable`, and it stays extension-safe
/// for M6.
public struct SaveActionsBar: View {
    /// Which way out the user took. Reported so the share extension can log
    /// it — once the extension closes there is no other way to know whether
    /// the share sheet ever opened.
    public enum Action: String, Sendable {
        case saveToNotes
        case copyAsText
        case shareAsText
    }

    private let note: OrganizedNote
    private let onAction: ((Action) -> Void)?

    @State private var markdownURL: URL?
    @State private var couldNotWriteFile = false
    @State private var showCopiedConfirmation = false
    @AppStorage("notesorganizer.hasSeenNotesImportHint") private var hasSeenImportHint = false

    public init(note: OrganizedNote, onAction: ((Action) -> Void)? = nil) {
        self.note = note
        self.onAction = onAction
    }

    public var body: some View {
        VStack(spacing: 12) {
            primaryAction
            secondaryActions
        }
        .task {
            NoteShareItem.removeStaleFiles()
            prepareMarkdownFile()
        }
    }

    // MARK: - Save to Apple Notes

    @ViewBuilder
    private var primaryAction: some View {
        if let markdownURL {
            ShareLink(item: markdownURL) {
                Label("Save to Apple Notes", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .simultaneousGesture(TapGesture().onEnded {
                hasSeenImportHint = true
                onAction?(.saveToNotes)
            })

            if !hasSeenImportHint {
                Text("Tap Notes → Import to save a formatted note.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else if couldNotWriteFile {
            Text("Couldn't prepare a file to save. You can still copy or share the text below.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    // MARK: - Copy / share as text

    private var secondaryActions: some View {
        HStack(spacing: 12) {
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

            ShareLink(item: PlainTextRenderer.render(note)) {
                Label("Share as text", systemImage: "text.alignleft")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .simultaneousGesture(TapGesture().onEnded {
                onAction?(.shareAsText)
            })
        }
    }

    // MARK: - Actions

    private func prepareMarkdownFile() {
        do {
            markdownURL = try NoteShareItem.makeMarkdownFile(for: note)
            couldNotWriteFile = false
        } catch {
            markdownURL = nil
            couldNotWriteFile = true
        }
    }

    private func copyAsText() {
        UIPasteboard.general.string = PlainTextRenderer.render(note)
        onAction?(.copyAsText)
        showCopiedConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showCopiedConfirmation = false
        }
    }
}

#Preview {
    SaveActionsBar(note: OrganizedNote(
        title: "Kitchen Renovation Notes",
        sections: [NoteSection(heading: "Quotes", bullets: ["Bosch quoted 4,200 for cabinets"])],
        actionItems: ["Call the contractor back on Thursday"]
    ))
    .padding()
}
