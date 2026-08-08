import NotesOrganizerKit
import SwiftUI

/// The one time TidyNote asks before any note text leaves the iPhone.
/// `CaptureViewModel` puts it up when the route it computed is a cloud one and
/// the answer isn't on file yet; the answer is kept in the App Group, so the
/// share extension honours it without ever being able to ask.
///
/// The copy says what happens, in that order, and stops. An "encrypted
/// connection" and "we don't keep your notes" are the two facts a reasonable
/// person would want before saying yes, and the third sentence is there so
/// nobody reads this as the app changing its mind about on-device tidies.
struct CloudConsentSheet: View {
    let onContinue: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            NoticeView(
                symbol: "sparkles",
                title: "Before your first premium tidy",
                message: """
                Your note's text is sent over an encrypted connection to our \
                servers, organized, and sent back. We don't keep your notes. \
                On-device tidies never leave your iPhone.
                """
            )

            VStack(spacing: 12) {
                Button("Continue", action: onContinue)
                    .buttonStyle(.borderedProminent)

                Button("Not now", action: onNotNow)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .presentationDetents([.medium])
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            CloudConsentSheet(onContinue: {}, onNotNow: {})
        }
}
