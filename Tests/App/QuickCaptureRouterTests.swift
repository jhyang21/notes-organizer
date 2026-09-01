import NotesOrganizerKit
import Testing
@testable import NotesOrganizer

@MainActor
@Suite("QuickCaptureRouter")
struct QuickCaptureRouterTests {
    /// The app's router is the shared one. This suite uses instances of its
    /// own, so a test can't leave a request waiting for the next one.
    @Test("nothing waiting is nothing to act on")
    func startsEmpty() {
        #expect(QuickCaptureRouter().take() == nil)
    }

    @Test("a request is handed over once")
    func takeHandsOverOnce() {
        let router = QuickCaptureRouter()

        router.request(.record)

        #expect(router.take() == .record)
        // Twice would be two recordings for one widget tap.
        #expect(router.take() == nil)
    }

    @Test("a second request replaces one nobody has taken yet")
    func laterRequestWins() {
        let router = QuickCaptureRouter()

        router.request(.record)
        router.request(.paywall)

        #expect(router.take() == .paywall)
    }
}
