import Foundation
import NotesOrganizerKit
import Observation
import UIKit

/// Drives the share flow: loading → organizing → preview, or an unavailable
/// state at any point. Mirrors `CaptureViewModel` in the app, minus
/// everything to do with recording — the text arrives already written.
///
/// Routing is injected the same way the app injects it, so a preview can use
/// `MockOrganizer` on a machine with no model.
///
/// The one thing this can't do that the app can is ask. There is no
/// RevenueCat SDK here and no first-run screen: it reads what the app wrote to
/// the App Group, and where that says "not yet" it points at the app.
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
    private let routing: OrganizeRouting

    init(routing: OrganizeRouting = OrganizeRouting(), log: DiagnosticsLog = .shared) {
        self.log = log
        self.routing = routing
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

    /// "Try again" on a failure screen. The text is still here, so a retry
    /// re-organizes it rather than sending the user back to Notes for it.
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

    /// The route is decided here, before anything is sent, because two of its
    /// outcomes are screens this process has to show instead: the quota wall,
    /// and a user who hasn't been told what TidyNote sends.
    private func organize(_ text: String) async {
        switch routing.route() {
        case .cloud:
            break
        case .consentNeeded:
            // Consent is a conversation, and this process can't have one.
            log.recordEvent(source: .shareExtension, message: "Organize skipped: cloud consent not granted")
            state = .unavailable(.cloudConsentNeeded)
            return
        case .blocked(let failure):
            log.recordEvent(source: .shareExtension, message: "Organize blocked: \(failure)")
            state = .unavailable(failure)
            return
        }

        state = .organizing(wordCount: WordCounter.count(text))

        switch await OrganizeRun(source: .shareExtension, log: log).run(text, with: routing.organizer()) {
        case .success(let outcome):
            state = .preview(outcome.note)
        case .failure(let failure):
            state = .unavailable(failure)
        case nil:
            break
        }
    }
}
