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
    /// Which way out the user took. Recorded because once the share sheet
    /// takes over there is no other way to know which one they picked — and
    /// in the extension, no way to know it opened at all.
    public enum Action: String, Sendable {
        case saveToNotes
        case copyAsText
        case shareAsText
    }

    private let note: OrganizedNote
    private let plainText: String
    private let source: DiagnosticsSource
    private let log: DiagnosticsLog

    @State private var markdownURL: URL?
    @State private var couldNotWriteFile = false
    @State private var showCopiedConfirmation = false

    // The App Group suite, so seeing the hint in the app also counts as
    // seeing it in the share extension.
    @AppStorage("notesorganizer.hasSeenNotesImportHint", store: AppGroup.defaults)
    private var hasSeenImportHint = false

    public init(note: OrganizedNote, source: DiagnosticsSource, log: DiagnosticsLog = .shared) {
        self.note = note
        self.plainText = PlainTextRenderer.render(note)
        self.source = source
        self.log = log
    }

    public var body: some View {
        VStack(spacing: 12) {
            primaryAction
            secondaryActions
        }
        .task {
            await prepareMarkdownFile()
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
                record(.saveToNotes)
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

            ShareLink(item: plainText) {
                Label("Share as text", systemImage: "text.alignleft")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .simultaneousGesture(TapGesture().onEnded {
                record(.shareAsText)
            })
        }
    }

    // MARK: - Actions

    /// Sweeping and writing are both synchronous `FileManager` work, so they
    /// run off the main actor; only the resulting state comes back to it.
    private func prepareMarkdownFile() async {
        let note = self.note
        let url = await Task.detached(priority: .userInitiated) { () -> URL? in
            NoteShareItem.removeStaleFiles()
            return try? NoteShareItem.makeMarkdownFile(for: note)
        }.value

        markdownURL = url
        couldNotWriteFile = url == nil
    }

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
