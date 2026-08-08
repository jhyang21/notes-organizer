import Foundation

/// Where `DiagnosticsLog` keeps its entries. A protocol so tests can swap in
/// an in-memory double instead of touching shared user defaults.
public protocol DiagnosticsStorage: Sendable {
    func data(forKey key: String) -> Data?
    func setData(_ data: Data?, forKey key: String)
}

/// The real storage: the App Group suite, so the app can read what the share
/// extension wrote.
///
/// A missing suite is normal, not an error — a simulator build without the
/// group entitlement gets `nil` from `UserDefaults(suiteName:)`. Reads then
/// return nothing and writes go nowhere, which costs the user a diagnostics
/// list and nothing else.
public struct UserDefaultsDiagnosticsStorage: DiagnosticsStorage, @unchecked Sendable {
    // `UserDefaults` is documented as thread-safe but isn't marked `Sendable`,
    // hence `@unchecked` rather than a lock of our own.
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    public func data(forKey key: String) -> Data? {
        defaults?.data(forKey: key)
    }

    public func setData(_ data: Data?, forKey key: String) {
        guard let defaults else { return }
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
