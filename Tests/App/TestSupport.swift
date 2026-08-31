import Foundation
import NotesOrganizerKit
import Testing

/// Stands in for the App Group suite, so nothing a test logs reaches the
/// simulator's shared storage. A lock rather than an actor because
/// `DiagnosticsStorage` is synchronous.
final class InMemoryDiagnosticsStorage: DiagnosticsStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        lock.withLock { values[key] }
    }

    func setData(_ data: Data?, forKey key: String) {
        lock.withLock {
            if let data {
                values[key] = data
            } else {
                values.removeValue(forKey: key)
            }
        }
    }
}

func makeLog() -> DiagnosticsLog {
    DiagnosticsLog(storage: InMemoryDiagnosticsStorage())
}

/// A `UserDefaults` suite of this test's own, removed when the object goes.
/// The app and the extension both read one shared suite in the field; a test
/// that used it would be reading whatever the last test wrote.
final class EphemeralDefaults {
    let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        let suiteName = "NotesOrganizerTests-\(UUID().uuidString)"
        self.suiteName = suiteName
        self.defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// A store with the plan already in the state a test needs.
///
/// - Parameter remaining: tidies left this month, or `nil` to leave the plan
///   unwritten — which is what a fresh install looks like.
func makeStore(
    _ defaults: EphemeralDefaults,
    consentGranted: Bool = true,
    remaining: Int? = nil
) -> EntitlementStore {
    let store = EntitlementStore(defaults: defaults.defaults)
    store.setCloudConsentGranted(consentGranted)
    if let remaining {
        store.recordQuota(
            used: max(0, PlanState.freeMonthlyLimit - remaining),
            limit: PlanState.freeMonthlyLimit,
            month: currentMonthKey(),
            isPro: false
        )
    }
    return store
}

/// The month label `EntitlementStore` counts against, worked out the way it
/// does: UTC, so a machine in any time zone reads its own quota.
func currentMonthKey() -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    let parts = calendar.dateComponents([.year, .month], from: Date())
    return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
}

/// Never answers. Stands in for a tidy still in flight, so a test can catch
/// a view model mid-wait or walk away from one; the sleep is what a
/// cancellation lands on.
struct SlowOrganizer: NoteOrganizing, VoiceOrganizing {
    func organize(_ text: String) async throws -> OrganizedNote {
        try await wait()
    }

    func organize(audioAt url: URL, durationSeconds: Double, locale: Locale) async throws -> OrganizedNote {
        try await wait()
    }

    private func wait() async throws -> OrganizedNote {
        try await Task.sleep(for: .seconds(60))
        return OrganizedNote(title: "Never", sections: [])
    }
}

struct WaitTimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "Timed out waiting for \(what)." }
}

/// Waits for something the object under test does on its own — a meter sample
/// landing, an organize coming back. Polls instead of sleeping a fixed
/// interval, so a passing test costs a millisecond or two and a stuck one
/// still ends.
@MainActor
func waitUntil(
    _ what: String,
    within limit: Duration = .seconds(5),
    _ condition: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while !condition() {
        guard clock.now < deadline else { throw WaitTimedOut(what: what) }
        try await Task.sleep(for: .milliseconds(1))
    }
}
