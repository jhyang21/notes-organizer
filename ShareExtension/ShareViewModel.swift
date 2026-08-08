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
/// RevenueCat SDK here and no consent sheet: it reads what the app wrote to
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

    func retry() async {
        await rerun(preference: .automatic)
    }

    /// "Try a premium tidy" on the on-device-failure screen. If the app hasn't
    /// been opened to agree to premium tidies, the route says so and the user
    /// gets told where to go — nothing is sent on a guess.
    func requestPremiumTidy() async {
        await rerun(preference: .forceCloud)
    }

    private func rerun(preference: RoutingPolicy.Preference) async {
        let trimmed = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .nothingToOrganize
            return
        }
        await organize(trimmed, preference: preference)
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
    /// The availability check that used to be left to the organizer happens
    /// here now, because the route needs it: whether this iPhone can tidy on
    /// its own is half of what decides where the text goes.
    private func organize(_ text: String, preference: RoutingPolicy.Preference = .automatic) async {
        let route = routing.route(preference: preference, onDeviceFailure: ModelAvailability.currentFailure())

        // Consent is a conversation, and this process can't have one.
        if case .consentNeeded = route {
            log.recordEvent(source: .shareExtension, message: "Organize skipped: cloud consent not granted")
            state = .unavailable(.cloudConsentNeeded)
            return
        }

        state = .organizing(wordCount: WordCounter.count(text))

        let organizer = routing.organizer(for: route, source: .shareExtension, log: log)
        switch await OrganizeRun(organizer: organizer, source: .shareExtension, log: log).run(text) {
        case .success(let outcome):
            state = .preview(outcome.note)
        case .failure(let failure):
            state = .unavailable(failure)
        case nil:
            break
        }
    }
}
