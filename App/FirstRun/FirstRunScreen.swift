import NotesOrganizerKit
import SwiftUI

/// The first thing a new install sees, before the record button. TidyNote
/// can't tidy anything without sending it, so it says so up front rather than
/// after the user has already talked into the microphone. The answer is kept
/// in the App Group, so this one screen covers the share extension too — which
/// has no way to ask.
///
/// One button, because there is no version of TidyNote that works without
/// this. A "Not now" would only lead to a record button that can't record.
struct FirstRunScreen: View {
    let onContinue: () -> Void

    private static let privacyPolicyURL = URL(string: "https://jhyang21.github.io/notes-organizer/privacy.html")!

    var body: some View {
        VStack(spacing: 24) {
            NoticeView(
                symbol: "sparkles",
                title: String(localized: "How TidyNote works"),
                message: String(localized: """
                TidyNote records your voice, sends the recording over an \
                encrypted connection to our servers, turns it into text, and \
                organizes it into a note. We don't keep your recordings or \
                your notes.
                """)
            )

            Link("Privacy Policy", destination: Self.privacyPolicyURL)
                .font(.footnote)

            Button("Continue", action: onContinue)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

#Preview {
    FirstRunScreen(onContinue: {})
}
