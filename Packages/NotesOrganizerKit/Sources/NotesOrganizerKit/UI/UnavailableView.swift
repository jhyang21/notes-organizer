import SwiftUI

/// What the user sees when there is no note to show: nothing worth
/// organizing, a spent month, no connection, a recording too long to send, or
/// a service having a bad minute. A `NoticeView` plus the copy and the way
/// forward for each `OrganizeFailure`.
///
/// Every case offers a way forward, and the way forward is specific — "Record
/// again" when we heard nothing, "See TidyNote Pro" when the month is spent.
/// A bare "Try again" where trying again can't work would only waste the
/// user's time.
///
/// Each action is a closure the caller may not have: a screen with no paywall
/// to open passes `nil` and the button doesn't appear. No copy here names a
/// model or a vendor — the user's vocabulary is "tidies".
public struct UnavailableView: View {
    private let failure: OrganizeFailure
    private let onRetry: (() -> Void)?
    private let onUpgrade: (() -> Void)?
    private let inShareExtension: Bool

    /// - Parameter inShareExtension: subscribing and getting started both
    ///   happen in the app and nowhere else. Set this where the app's screens
    ///   can't be reached, and those two dead ends say where the switch lives
    ///   instead of showing a button that couldn't work.
    public init(
        failure: OrganizeFailure,
        onRetry: (() -> Void)? = nil,
        onUpgrade: (() -> Void)? = nil,
        inShareExtension: Bool = false
    ) {
        self.failure = failure
        self.onRetry = onRetry
        self.onUpgrade = onUpgrade
        self.inShareExtension = inShareExtension
    }

    public var body: some View {
        NoticeView(symbol: symbolName, title: title, message: message) {
            actions
        }
        .padding()
        // A dead end is a state a user can land on without any layout change
        // to draw VoiceOver's attention to it — announce it explicitly rather
        // than trust focus-follows-layout, which varies by device and OS.
        // `CaptureFailure` already announces from `CaptureScreen`'s onChange,
        // so this stays here rather than in `NoticeView` to avoid a double
        // announcement of the same failure.
        .onAppear {
            AccessibilityNotification.Announcement(title).post()
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch failure {
        case .networkUnavailable, .cloudUnavailable:
            retryButton(title: "Try again")

        case .emptyTranscript, .audioTooLarge:
            retryButton(title: "Record again")

        case .cloudQuotaExhausted:
            if inShareExtension {
                openAppHint("Open TidyNote to go Pro.")
            } else if let onUpgrade {
                Button("See TidyNote Pro", action: onUpgrade)
                    .buttonStyle(.borderedProminent)
            }

        case .cloudConsentNeeded:
            if inShareExtension {
                openAppHint("Open TidyNote once to get started.")
            } else {
                // The app asks on first launch, so this shouldn't be reachable
                // in it. Retrying recomputes the route, which puts the
                // first-run screen up rather than leaving a dead end.
                retryButton(title: "Try again")
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
        case .emptyTranscript: "mic.slash"
        case .cloudQuotaExhausted: "sparkles"
        case .cloudConsentNeeded: "hand.raised"
        case .networkUnavailable: "wifi.slash"
        case .audioTooLarge: "waveform"
        case .cloudUnavailable: "cloud.slash"
        }
    }

    private var title: String {
        switch failure {
        case .emptyTranscript: "We didn't catch anything"
        case .cloudQuotaExhausted: "You've used this month's tidies"
        case .cloudConsentNeeded: "TidyNote isn't set up yet"
        case .networkUnavailable: "You're offline"
        case .audioTooLarge: "That recording is too long"
        case .cloudUnavailable: "The tidy service hit a snag"
        }
    }

    private var message: String {
        switch failure {
        case .emptyTranscript:
            "There wasn't enough there to organize. Record again and speak for a few seconds."
        case .cloudQuotaExhausted:
            "They come back next month, or go unlimited with TidyNote Pro. Nothing was lost — your text is still here."
        case .cloudConsentNeeded:
            "TidyNote says what it sends and asks once, in the app, before anything leaves your iPhone."
        case .networkUnavailable:
            "TidyNote needs a connection to tidy a note. Nothing was lost — try again when you're back online."
        case .audioTooLarge:
            "That recording is longer than TidyNote can handle. Try recording it in two parts."
        case .cloudUnavailable(let reason):
            reason
        }
    }
}

#Preview("Empty transcript") {
    UnavailableView(failure: .emptyTranscript, onRetry: {})
}

#Preview("Quota exhausted") {
    UnavailableView(failure: .cloudQuotaExhausted, onUpgrade: {})
}

#Preview("Offline") {
    UnavailableView(failure: .networkUnavailable, onRetry: {})
}

#Preview("Recording too long") {
    UnavailableView(failure: .audioTooLarge, onRetry: {})
}

#Preview("Quota exhausted, share extension") {
    UnavailableView(failure: .cloudQuotaExhausted, inShareExtension: true)
}

#Preview("Not set up, share extension") {
    UnavailableView(failure: .cloudConsentNeeded, inShareExtension: true)
}
