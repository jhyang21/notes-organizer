import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Answers "can this device organize a note at all?" without recording
/// anything first. The app asks on screen appear so an ineligible iPhone
/// shows `UnavailableView` immediately, rather than after the user has
/// talked for a minute.
///
/// Marked `@MainActor` deliberately: `SystemLanguageModel` is a system
/// observable object, and touching it from the main actor is safe whatever
/// isolation Apple declares for it.
public enum ModelAvailability {
    /// `nil` when the on-device model is ready to use; otherwise the failure
    /// the UI should show.
    @MainActor
    public static func currentFailure() -> OrganizeFailure? {
        #if canImport(FoundationModels)
        // `if case` rather than an exhaustive switch, and `.modelNotReady`
        // reached via `default`: both keep this compiling if Apple adds an
        // availability or unavailability case.
        guard case .unavailable(let reason) = SystemLanguageModel.default.availability else { return nil }

        switch reason {
        case .deviceNotEligible:
            return .deviceNotEligible
        case .appleIntelligenceNotEnabled:
            return .appleIntelligenceNotEnabled
        default:
            return .modelNotReady(reason: "The on-device model is still getting ready. Try again in a moment.")
        }
        #else
        return .deviceNotEligible
        #endif
    }
}
