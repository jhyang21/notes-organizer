import NotesOrganizerKit
import Observation

/// Where a request from outside the app waits until the capture screen can act
/// on it.
///
/// A widget tap, a Siri phrase and a `tidynote://` link all arrive somewhere
/// the app's screens are not: an `AppIntent` runs outside SwiftUI entirely, and
/// a cold launch's URL lands before the first view exists. Each of them leaves
/// the request here. The capture screen takes it when it appears, and again
/// whenever a new one lands.
@MainActor
@Observable
final class QuickCaptureRouter {
    /// The instance the app uses. One process, one window, one capture screen.
    static let shared = QuickCaptureRouter()

    private(set) var pending: QuickCaptureLink?

    func request(_ link: QuickCaptureLink) {
        pending = link
    }

    /// Hands the waiting request over exactly once, and clears it whether the
    /// caller can act on it or not. A request left behind is one an identical
    /// tap can't replace — the value wouldn't change, the screen wouldn't
    /// notice, and the widget would look broken from then on.
    func take() -> QuickCaptureLink? {
        defer { pending = nil }
        return pending
    }
}
