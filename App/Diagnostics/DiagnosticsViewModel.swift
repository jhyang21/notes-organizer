import Foundation
import NotesOrganizerKit
import Observation
import UIKit

/// State for the diagnostics screen: the Markdown import sample, and whatever
/// the app and the share extension have written to the shared log.
///
/// It runs nothing itself. Every tidy costs a call now, and a workbench that
/// spends a user's month on a sample would be a trap rather than a tool — the
/// timings table below already shows what real runs cost.
@MainActor
@Observable
final class DiagnosticsViewModel {
    private(set) var markdownSampleURL: URL?
    private(set) var markdownSampleError: String?

    private(set) var sharePayloads: [SharePayloadObservation] = []
    private(set) var organizeTimings: [OrganizeTiming] = []
    private(set) var events: [DiagnosticsEvent] = []

    private let log: DiagnosticsLog

    init(log: DiagnosticsLog = .shared) {
        self.log = log
    }

    // MARK: - Refresh

    func refresh() {
        sharePayloads = log.sharePayloads()
        organizeTimings = log.organizeTimings()
        events = log.events()
    }

    func clearLog() {
        log.clear()
        refresh()
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
