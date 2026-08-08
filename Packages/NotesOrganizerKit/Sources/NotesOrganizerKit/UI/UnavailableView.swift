import SwiftUI
import UIKit

/// What the user sees when there is no note to show: no Apple Intelligence
/// on the device, a model that isn't ready, or nothing worth organizing.
/// A `NoticeView` plus the copy and the way forward for each `OrganizeFailure`.
///
/// Every case except `deviceNotEligible` offers a way forward, and the way
/// forward is specific — "Open Settings" when Apple Intelligence is off,
/// "Record again" when we heard nothing. A generic "Try again" on a device
/// that can never run the model would just waste the user's time.
///
/// Each action is a closure the caller may not have: a screen with no way to
/// start a premium tidy passes `nil` and the button doesn't appear. No copy
/// here names a model or a vendor — the user's vocabulary is "tidies" and
/// "premium tidies".
public struct UnavailableView: View {
    private let failure: OrganizeFailure
    private let onRetry: (() -> Void)?
    private let onPremiumTidy: (() -> Void)?
    private let onUpgrade: (() -> Void)?
    private let inShareExtension: Bool

    @Environment(\.openURL) private var openURL

    /// - Parameter inShareExtension: subscribing and agreeing to premium
    ///   tidies both happen in the app and nowhere else. Set this where the
    ///   app's screens can't be reached, and those two dead ends say where the
    ///   switch lives instead of showing a button that couldn't work.
    public init(
        failure: OrganizeFailure,
        onRetry: (() -> Void)? = nil,
        onPremiumTidy: (() -> Void)? = nil,
        onUpgrade: (() -> Void)? = nil,
        inShareExtension: Bool = false
    ) {
        self.failure = failure
        self.onRetry = onRetry
        self.onPremiumTidy = onPremiumTidy
        self.onUpgrade = onUpgrade
        self.inShareExtension = inShareExtension
    }

    public var body: some View {
        NoticeView(symbol: symbolName, title: title, message: message) {
            actions
        }
        .padding()
    }

    @ViewBuilder
    private var actions: some View {
        switch failure {
        case .deviceNotEligible:
            EmptyView()

        case .appleIntelligenceNotEnabled:
            Button("Open Settings") {
                // Deep-linking straight to the Apple Intelligence pane isn't
                // a documented URL; the app's own Settings page is, and it's
                // one tap from there.
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .buttonStyle(.borderedProminent)

        case .modelNotReady, .contextOverflow, .networkUnavailable, .cloudUnavailable:
            retryButton(title: "Try again")

        case .emptyTranscript:
            retryButton(title: "Record again")

        case .onDeviceFailed:
            // A premium tidy is the only thing left that might organize this
            // text, so it leads; the plain retry stays for a model that was
            // merely having a bad minute.
            if let onPremiumTidy {
                Button("Try a premium tidy", action: onPremiumTidy)
                    .buttonStyle(.borderedProminent)
            }
            if let onRetry {
                Button("Try again", action: onRetry)
                    .buttonStyle(.bordered)
            }

        case .cloudQuotaExhausted:
            if inShareExtension {
                openAppHint("Open TidyNote to go Pro.")
            } else if let onUpgrade {
                Button("See TidyNote Pro", action: onUpgrade)
                    .buttonStyle(.borderedProminent)
            }

        case .cloudConsentNeeded:
            if inShareExtension {
                openAppHint("Open TidyNote to allow premium tidies.")
            } else {
                // The retry recomputes the route, which lands back on
                // "consent needed" and puts the question on screen again.
                retryButton(title: "Allow premium tidies")
            }
        }
    }

    @ViewBuilder
    private func retryButton(title: String) -> some View {
        if let onRetry {
            Button(title, action: onRetry)
                .buttonStyle(.borderedProminent)
        }
    }

    private func openAppHint(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .multilineTextAlignment(.center)
    }

    // MARK: - Copy

    private var symbolName: String {
        switch failure {
        case .deviceNotEligible: "iphone.slash"
        case .appleIntelligenceNotEnabled: "gearshape"
        case .modelNotReady: "clock.arrow.circlepath"
        case .emptyTranscript: "mic.slash"
        case .contextOverflow: "doc.text.magnifyingglass"
        case .onDeviceFailed: "exclamationmark.triangle"
        case .cloudQuotaExhausted: "sparkles"
        case .cloudConsentNeeded: "hand.raised"
        case .networkUnavailable: "wifi.slash"
        case .cloudUnavailable: "cloud.slash"
        }
    }

    private var title: String {
        switch failure {
        case .deviceNotEligible: "This iPhone can't run TidyNote"
        case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence"
        case .modelNotReady: "The model isn't ready yet"
        case .emptyTranscript: "We didn't catch anything"
        case .contextOverflow: "That note is too long"
        case .onDeviceFailed: "Couldn't tidy this on your iPhone"
        case .cloudQuotaExhausted: "You've used this month's premium tidies"
        case .cloudConsentNeeded: "Premium tidies need the cloud"
        case .networkUnavailable: "You're offline"
        case .cloudUnavailable: "The tidy service hit a snag"
        }
    }

    private var message: String {
        switch failure {
        case .deviceNotEligible:
            "Organizing runs entirely on your iPhone, which needs Apple Intelligence — iPhone 15 Pro or later."
        case .appleIntelligenceNotEnabled:
            "TidyNote uses Apple Intelligence on your iPhone to organize notes. Turn it on in Settings, then come back."
        case .modelNotReady(let reason):
            reason
        case .emptyTranscript:
            "There wasn't enough there to organize. Record again and speak for a few seconds."
        case .contextOverflow:
            "This one is long enough that it won't fit in a single pass. Try splitting it into two notes."
        case .onDeviceFailed:
            "The on-device model couldn't organize this text without losing content. Nothing was lost."
        case .cloudQuotaExhausted:
            "They come back next month, or go unlimited with TidyNote Pro. Nothing was lost — your text is still here."
        case .cloudConsentNeeded:
            "A premium tidy sends the note's text to our servers to be organized, and you haven't agreed to that yet. Tidies that run on your iPhone never leave it."
        case .networkUnavailable:
            "Premium tidies need an internet connection. Nothing was lost — try again when you're back online."
        case .cloudUnavailable(let reason):
            reason
        }
    }
}

#Preview("Not enabled") {
    UnavailableView(failure: .appleIntelligenceNotEnabled)
}

#Preview("Empty transcript") {
    UnavailableView(failure: .emptyTranscript, onRetry: {})
}

#Preview("On-device failed") {
    UnavailableView(failure: .onDeviceFailed, onRetry: {}, onPremiumTidy: {})
}

#Preview("Quota exhausted") {
    UnavailableView(failure: .cloudQuotaExhausted, onUpgrade: {})
}

#Preview("Consent needed") {
    UnavailableView(failure: .cloudConsentNeeded, onRetry: {})
}

#Preview("Quota exhausted, share extension") {
    UnavailableView(failure: .cloudQuotaExhausted, inShareExtension: true)
}
