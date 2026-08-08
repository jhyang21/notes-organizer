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
        case failed(message: String)
    }

    private(set) var state: State = .loading

    /// Kept for the "Copy original text" escape hatch, so a failure never
    /// leaves the user holding nothing.
    private(set) var originalText = ""

    private let organizer: NoteOrganizing
    private let log: DiagnosticsLog
    private let clock = ContinuousClock()

    init(organizer: NoteOrganizing = FoundationModelOrganizer(), log: DiagnosticsLog = .shared) {
        self.organizer = organizer
        self.log = log
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

        // Asked before organizing so an ineligible iPhone says so straight
        // away instead of after a wait that was never going to work.
        if let failure = ModelAvailability.currentFailure() {
            log.recordEvent(source: .shareExtension, message: "Model unavailable: \(failure)")
            state = .unavailable(failure)
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

    func recordSaveAction(_ action: SaveActionsBar.Action) {
        log.recordEvent(source: .shareExtension, message: "Save action: \(action.rawValue)")
    }

    // MARK: - Organizing

    /// Runs in this process on purpose: FoundationModels does its work in a
    /// system process, so the extension's memory limit isn't the constraint
    /// it would be for a model loaded in-process.
    private func organize(_ text: String) async {
        let words = WordCounter.count(text)
        state = .organizing(wordCount: words)

        let started = clock.now
        do {
            let note = try await organizer.organize(text)
            log.recordOrganizeTiming(
                source: .shareExtension,
                wordCount: words,
                duration: (clock.now - started).totalSeconds
            )
            state = .preview(note)
        } catch let failure as OrganizeFailure {
            log.recordEvent(source: .shareExtension, message: "Organize failed: \(failure)")
            state = .unavailable(failure)
        } catch {
            log.recordEvent(source: .shareExtension, message: "Organize error: \(error.localizedDescription)")
            state = .failed(message: error.localizedDescription)
        }
    }
}
