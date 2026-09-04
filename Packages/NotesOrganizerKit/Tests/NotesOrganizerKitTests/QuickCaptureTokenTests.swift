import Foundation
import Testing
@testable import NotesOrganizerKit

@Suite("QuickCaptureToken")
struct QuickCaptureTokenTests {
    /// A throwaway suite per test, removed afterwards, so nothing leaks into
    /// the next test or the machine running it.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "QuickCaptureTokenTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    @Test("there is no token until a launch mints one")
    func nothingBeforeTheFirstRotation() throws {
        try withDefaults { defaults in
            #expect(QuickCaptureToken.current(defaults: defaults) == nil)
            #expect(QuickCaptureToken.accepted(defaults: defaults).isEmpty)
        }
    }

    @Test("rotating mints a new token and hands back what it stored")
    func rotateStoresWhatItReturns() throws {
        try withDefaults { defaults in
            let first = QuickCaptureToken.rotate(defaults: defaults)

            #expect(QuickCaptureToken.current(defaults: defaults) == first)

            let second = QuickCaptureToken.rotate(defaults: defaults)

            #expect(second != first)
            #expect(QuickCaptureToken.current(defaults: defaults) == second)
        }
    }

    /// One rotation of grace, so a widget the system hasn't redrawn yet still
    /// opens the microphone.
    @Test("the token a rotation retires is accepted one more time")
    func theRetiredTokenIsStillAccepted() throws {
        try withDefaults { defaults in
            let first = QuickCaptureToken.rotate(defaults: defaults)
            let second = QuickCaptureToken.rotate(defaults: defaults)

            #expect(QuickCaptureToken.accepted(defaults: defaults) == [second, first])

            let third = QuickCaptureToken.rotate(defaults: defaults)

            #expect(QuickCaptureToken.accepted(defaults: defaults) == [third, second])
        }
    }

    @Test("a build without the App Group degrades to no-ops")
    func missingSuiteIsSafe() {
        _ = QuickCaptureToken.rotate(defaults: nil)

        #expect(QuickCaptureToken.current(defaults: nil) == nil)
        #expect(QuickCaptureToken.accepted(defaults: nil).isEmpty)
    }
}
