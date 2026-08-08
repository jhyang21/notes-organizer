import Foundation

public extension Duration {
    /// The whole duration as seconds, for logging and display. `components`
    /// splits into seconds and attoseconds; every caller here wants one
    /// number.
    var totalSeconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
