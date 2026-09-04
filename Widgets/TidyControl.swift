import AppIntents
import NotesOrganizerKit
import SwiftUI
import WidgetKit

/// The same one tap, in Control Center, on the Lock Screen's two corners, or
/// bound to the Action button.
///
/// It opens the link the widget opens. A control can run an intent without
/// leaving the current screen, but this one has to leave: recording needs the
/// app in front of the user, and `OpenURLIntent` says so plainly instead of
/// pretending otherwise and opening the app anyway.
@available(iOS 18.0, *)
struct TidyControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.immform.notesorganizer.widgets.tidy") {
            // Read inside the closure so every render picks up the token the
            // last launch minted. Without one the control still opens the app,
            // it just doesn't start recording.
            let url = QuickCaptureToken.current().map(QuickCaptureLink.recordURL(token:))
                ?? QuickCaptureLink.open.url
            ControlWidgetButton(action: OpenURLIntent(url)) {
                Label("Start a Tidy", systemImage: "mic.fill")
            }
        }
        .displayName("Start a Tidy")
        .description("Opens TidyNote and starts recording.")
    }
}
