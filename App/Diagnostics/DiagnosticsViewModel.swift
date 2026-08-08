import Foundation
import NotesOrganizerKit
import Observation
import UIKit

/// State for the diagnostics screen: what the model says about itself, what
/// two sample runs did, and whatever the app and the share extension have
/// written to the shared log.
@MainActor
@Observable
final class DiagnosticsViewModel {
    enum ModelStatus: Equatable {
        case checking
        case ready
        case unavailable(OrganizeFailure)
    }

    struct RunResult: Equatable {
        var seconds: TimeInterval
        var wordCount: Int
        var title: String
        var sectionCount: Int
        var actionItemCount: Int
    }

    enum RunState: Equatable {
        case idle
        case running
        case succeeded(RunResult)
        case failed(String)
    }

    private(set) var modelStatus: ModelStatus = .checking
    private(set) var helloWorld: RunState = .idle
    private(set) var benchmark: RunState = .idle

    private(set) var markdownSampleURL: URL?
    private(set) var markdownSampleError: String?

    private(set) var sharePayloads: [SharePayloadObservation] = []
    private(set) var organizeTimings: [OrganizeTiming] = []
    private(set) var events: [DiagnosticsEvent] = []

    private let log: DiagnosticsLog
    private let organizeRun: OrganizeRun

    init(organizer: NoteOrganizing = FoundationModelOrganizer(), log: DiagnosticsLog = .shared) {
        self.log = log
        self.organizeRun = OrganizeRun(organizer: organizer, source: .app, log: log)
    }

    // MARK: - Refresh

    func refresh() {
        modelStatus = ModelAvailability.currentFailure().map(ModelStatus.unavailable) ?? .ready
        sharePayloads = log.sharePayloads()
        organizeTimings = log.organizeTimings()
        events = log.events()
    }

    func clearLog() {
        log.clear()
        refresh()
    }

    // MARK: - Sample runs

    func runShortSample() async {
        helloWorld = await run(DiagnosticsSamples.short)
        refresh()
    }

    func runLongSample() async {
        benchmark = await run(DiagnosticsSamples.long)
        refresh()
    }

    private func run(_ sample: String) async -> RunState {
        switch await organizeRun.run(sample) {
        case .success(let outcome):
            return .succeeded(RunResult(
                seconds: outcome.duration,
                wordCount: outcome.wordCount,
                title: outcome.note.title,
                sectionCount: outcome.note.sections.count,
                actionItemCount: outcome.note.actionItems.count
            ))
        case .failure(let failure):
            return .failed("\(failure)")
        case nil:
            return .idle
        }
    }

    // MARK: - Markdown import check

    /// Writes the same kind of `.md` file the save path writes, so sharing it
    /// to Notes answers the one question only a device can: does Notes'
    /// Import keep the headings.
    func prepareMarkdownSample() {
        let note = OrganizedNote(
            title: "Markdown Import Check",
            sections: [
                NoteSection(heading: "Headings", bullets: [
                    "This line should sit under a bold heading called Headings",
                    "A second bullet, to check list formatting",
                ]),
                NoteSection(heading: "Numbers and names", bullets: [
                    "Marco quoted 11,200 for the cabinets on 12 March",
                ]),
            ],
            actionItems: ["Check this note kept its structure"]
        )

        do {
            markdownSampleURL = try NoteShareItem.makeMarkdownFile(for: note)
            markdownSampleError = nil
        } catch {
            markdownSampleURL = nil
            markdownSampleError = error.localizedDescription
        }
    }

    func recordMarkdownShareTapped() {
        log.recordEvent(source: .app, message: "Shared the Markdown import sample")
    }

    // MARK: - Device

    var systemVersion: String {
        "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    }

    /// On a simulator `uname` reports the Mac's architecture, so the
    /// simulated device's identifier comes from the environment instead.
    var deviceModelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated) (simulator)"
        }

        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return identifier.isEmpty ? "unknown" : identifier
    }
}
