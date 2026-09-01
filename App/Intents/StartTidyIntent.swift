import AppIntents
import NotesOrganizerKit

/// "Start a tidy in TidyNote" — the app's one intent, from Siri, from
/// Shortcuts, and from Spotlight.
///
/// It opens the app because it has to: a tidy starts at the microphone, and
/// the microphone needs the app in front of the user. So the intent does the
/// same thing the widget does — leave the request where the capture screen
/// will find it — and lets the system bring the app forward.
struct StartTidyIntent: AppIntent {
    static var title: LocalizedStringResource { "Start a Tidy" }

    static var description: IntentDescription {
        IntentDescription("Opens TidyNote and starts recording straight away.")
    }

    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        // Hopped explicitly rather than by isolating `perform` itself: the
        // router is main-actor state, and this reads the same whether or not
        // the framework already put us there.
        await MainActor.run {
            QuickCaptureRouter.shared.request(.record)
        }
        return .result()
    }
}

/// What makes the intent findable without the user building a shortcut first.
/// Every phrase has to name the app — the system needs to know which app is
/// being asked.
struct TidyNoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartTidyIntent(),
            phrases: [
                "Start a tidy in \(.applicationName)",
                "New tidy in \(.applicationName)",
                "Start recording in \(.applicationName)"
            ],
            shortTitle: "Start a Tidy",
            systemImageName: "mic.circle.fill"
        )
    }
}
