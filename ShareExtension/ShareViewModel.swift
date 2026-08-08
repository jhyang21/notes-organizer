import Foundation
import NotesOrganizerKit
import Observation
import UIKit

/// Drives the share flow: loading → organizing → preview, or an unavailable
/// state at any point. Mirrors `CaptureViewModel` in the app, minus
/// everything to do with recording — the text arrives already written.
///
/// The organizer is injected the same way the app injects it, so a preview
/// can use `MockOrganizer` on a machine with no model.
@MainActor
@Observable
final class ShareViewModel {
    enum State: Equatable {
        case loading
        case organizing(wordCount: Int)
        case preview(OrganizedNote)
        case nothingToOrganize
        case unavailable(OrganizeFailure)
    }

    private(set) var state: State = .loading

    /// Kept for the "Copy original text" escape hatch, so a failure never
    /// leaves the user holding nothing.
    private(set) var originalText = ""

    private let log: DiagnosticsLog
    private let organizeRun: OrganizeRun

    init(organizer: NoteOrganizing = FoundationModelOrganizer(), log: DiagnosticsLog = .shared) {
        self.log = log
        self.organizeRun = OrganizeRun(organizer: organizer, source: .shareExtension, log: log)
    }

    // MARK: - Flow

    func start(with items: [NSExtensionItem]) async {
        state = .loading

        let loaded = await SharedTextLoader.load(from: items, log: log)
        originalText = loaded.text

        let trimmed = loaded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log.recordEvent(source: .shareExtension, message: "No text in the shared payload")
            state = .nothingToOrganize
            return
        }

        await organize(trimmed)
    }

    func retry() async {
        let trimmed = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .nothingToOrganize
            return
        }
        await organize(trimmed)
    }

    func copyOriginalText() {
        UIPasteboard.general.string = originalText
        log.recordEvent(source: .shareExtension, message: "Copied the original text")
    }

    // MARK: - Organizing

    /// Runs in this process on purpose: FoundationModels does its work in a
    /// system process, so the extension's memory limit isn't the constraint
    /// it would be for a model loaded in-process.
    ///
    /// No model-availability pre-check: the organizer makes the same check
    /// first thing and throws the same failure, so asking here would only
    /// log the one condition twice.
    private func organize(_ text: String) async {
        state = .organizing(wordCount: WordCounter.count(text))

        switch await organizeRun.run(text) {
        case .success(let outcome):
            state = .preview(outcome.note)
        case .failure(let failure):
            state = .unavailable(failure)
        case nil:
            break
        }
    }
}
