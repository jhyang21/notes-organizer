import SwiftUI

/// What the user sees when there is no note to show: nothing worth
/// organizing, a spent month, no connection, a recording too long to send, or
/// a service having a bad minute. A `NoticeView` plus the copy and the way
/// forward for each `OrganizeFailure`.
///
/// Every case offers a way forward, and the way forward is specific — "Record
/// Again" when we heard nothing, "See TidyNote Pro" when the month is spent.
/// A bare "Try Again" where trying again can't work would only waste the
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
    private let onOpenApp: ((URL) -> Void)?

    /// - Parameter inShareExtension: subscribing and getting started both
    ///   happen in the app and nowhere else. Set this where the app's screens
    ///   can't be reached, and those two dead ends say where the switch lives
    ///   instead of showing a button that couldn't work.
    /// - Parameter onOpenApp: opens the app at the link handed to it. Where the
    ///   host can hand off, the two share-extension hints become the buttons
    ///   they describe; `nil` keeps the hint, which is what a host that can't
    ///   open a URL leaves behind. Only read alongside `inShareExtension` — the
    ///   app has its own way to reach both screens.
    public init(
        failure: OrganizeFailure,
        onRetry: (() -> Void)? = nil,
        onUpgrade: (() -> Void)? = nil,
        inShareExtension: Bool = false,
        onOpenApp: ((URL) -> Void)? = nil
    ) {
        self.failure = failure
        self.onRetry = onRetry
        self.onUpgrade = onUpgrade
        self.inShareExtension = inShareExtension
        self.onOpenApp = onOpenApp
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
            retryButton(title: String(localized: "Try Again", bundle: .module))

        case .emptyTranscript:
            if inShareExtension {
                retryButton(title: String(localized: "Try Again", bundle: .module))
            } else {
                retryButton(title: String(localized: "Record Again", bundle: .module))
            }

        case .audioTooLarge:
            retryButton(title: String(localized: "Record Again", bundle: .module))

        case .cloudQuotaExhausted:
            if inShareExtension {
                openApp(
                    .paywall,
                    title: String(localized: "See TidyNote Pro", bundle: .module),
                    hint: String(localized: "Open TidyNote to go Pro.", bundle: .module)
                )
            } else if let onUpgrade {
                Button(String(localized: "See TidyNote Pro", bundle: .module), action: onUpgrade)
                    .buttonStyle(.borderedProminent)
            }

        case .cloudConsentNeeded:
            if inShareExtension {
                openApp(
                    .open,
                    title: String(localized: "Open TidyNote", bundle: .module),
                    hint: String(localized: "Open TidyNote once to get started.", bundle: .module)
                )
            } else {
                // The app asks on first launch, so this shouldn't be reachable
                // in it. Retrying recomputes the route, which puts the
                // first-run screen up rather than leaving a dead end.
                retryButton(title: String(localized: "Try Again", bundle: .module))
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

    /// The button when the host can hand the user to the app, the sentence
    /// saying where to go when it can't. A share extension is officially free
    /// to refuse to open a URL, so the sentence is not a fallback we expect to
    /// go unused.
    @ViewBuilder
    private func openApp(_ link: QuickCaptureLink, title: String, hint: String) -> some View {
        if let onOpenApp {
            Button(title) { onOpenApp(link.url) }
                .buttonStyle(.borderedProminent)
        } else {
            Text(hint)
                .font(.footnote.weight(.medium))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Copy

    private var symbolName: String {
        switch failure {
        // Shares a symbol with `CaptureFailure.emptyRecording` — both read as
        // "nothing there to work with".
        case .emptyTranscript: "waveform.slash"
        case .cloudQuotaExhausted: "sparkles"
        case .cloudConsentNeeded: "hand.raised"
        case .networkUnavailable: "wifi.slash"
        case .audioTooLarge: "waveform"
        case .cloudUnavailable: "cloud.slash"
        }
    }

    private var title: String {
        switch failure {
        case .emptyTranscript:
            if inShareExtension {
                String(localized: "There's not enough text to organize.", bundle: .module)
            } else {
                String(localized: "Nothing to tidy", bundle: .module)
            }
        case .cloudQuotaExhausted: String(localized: "You've used this month's tidies", bundle: .module)
        case .cloudConsentNeeded: String(localized: "TidyNote isn't set up yet", bundle: .module)
        case .networkUnavailable: String(localized: "You're offline", bundle: .module)
        case .audioTooLarge: String(localized: "That recording is too long", bundle: .module)
        case .cloudUnavailable: String(localized: "The tidy service hit a snag", bundle: .module)
        }
    }

    private var message: String {
        switch failure {
        case .emptyTranscript:
            if inShareExtension {
                String(localized: "Share a note with a few sentences in it and TidyNote will structure it.", bundle: .module)
            } else {
                String(localized: "We didn't catch enough to organize. Speak for a few seconds and try again.", bundle: .module)
            }
        case .cloudQuotaExhausted:
            String(localized: "They come back next month, or go unlimited with TidyNote Pro.", bundle: .module)
        case .cloudConsentNeeded:
            String(localized: "TidyNote says what it sends and asks once, in the app, before anything leaves your iPhone.", bundle: .module)
        case .networkUnavailable:
            String(localized: "TidyNote needs a connection to tidy a note. Nothing was lost — try again when you're back online.", bundle: .module)
        case .audioTooLarge:
            String(localized: "That recording is longer than TidyNote can handle. Try recording it in two parts.", bundle: .module)
        case .cloudUnavailable(let reason):
            reason
        }
    }
}

#Preview("Empty transcript") {
    UnavailableView(failure: .emptyTranscript, onRetry: {})
}

#Preview("Empty transcript, share extension") {
    UnavailableView(failure: .emptyTranscript, onRetry: {}, inShareExtension: true)
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

#Preview("Quota exhausted, share extension that can open the app") {
    UnavailableView(failure: .cloudQuotaExhausted, inShareExtension: true, onOpenApp: { _ in })
}

#Preview("Not set up, share extension that can open the app") {
    UnavailableView(failure: .cloudConsentNeeded, inShareExtension: true, onOpenApp: { _ in })
}
