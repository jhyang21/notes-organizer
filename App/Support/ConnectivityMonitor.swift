import Foundation
import Network

/// Whether the phone has a usable network path. Behind a protocol so a
/// test can say "airplane mode" without one.
protocol ConnectivityChecking: Sendable {
    func isOnline() async -> Bool
}

/// What the last path update said, and the wait for a first one. Split
/// from the monitor so the one rule that matters, unknown means let them
/// through, is testable without a network to take away.
final class ConnectivityState: @unchecked Sendable {
    private let lock = NSLock()
    private var known: Bool?

    func record(isOnline: Bool) { lock.withLock { known = isOnline } }

    /// Waits for the first answer, up to `timeout`, then answers with
    /// what it has. No answer reads as online: a wrong "offline" stops
    /// someone recording, a wrong "online" only costs an upload that
    /// already fails cleanly.
    func resolved(waitingUpTo timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let known = lock.withLock({ known }) { return known }
            guard ContinuousClock.now < deadline else { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// `NWPathMonitor`, started once at launch and kept for the process.
final class ConnectivityMonitor: ConnectivityChecking, @unchecked Sendable {
    static let shared = ConnectivityMonitor()

    private let monitor = NWPathMonitor()
    private let state = ConnectivityState()
    private let startLock = NSLock()
    private var isStarted = false

    /// Idempotent. A path monitor watches the stack; it opens nothing.
    func start() {
        let alreadyStarted = startLock.withLock { defer { isStarted = true }; return isStarted }
        guard !alreadyStarted else { return }
        monitor.pathUpdateHandler = { [state] path in
            // `.requiresConnection` is an on-demand VPN waiting to be
            // asked; only `.unsatisfied` means there is no way out.
            state.record(isOnline: path.status != .unsatisfied)
        }
        monitor.start(queue: DispatchQueue(label: "com.immform.notesorganizer.connectivity"))
    }

    func isOnline() async -> Bool {
        start()
        return await state.resolved(waitingUpTo: .milliseconds(300))
    }
}
