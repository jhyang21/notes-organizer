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
public struct UnavailableView: View {
    private let failure: OrganizeFailure
    private let onRetry: (() -> Void)?

    @Environment(\.openURL) private var openURL

    public init(failure: OrganizeFailure, onRetry: (() -> Void)? = nil) {
        self.failure = failure
        self.onRetry = onRetry
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

        case .modelNotReady, .contextOverflow:
            retryButton(title: "Try again")

        case .emptyTranscript:
            retryButton(title: "Record again")
        }
    }

    @ViewBuilder
    private func retryButton(title: String) -> some View {
        if let onRetry {
            Button(title, action: onRetry)
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Copy

    private var symbolName: String {
        switch failure {
        case .deviceNotEligible: "iphone.slash"
        case .appleIntelligenceNotEnabled: "gearshape"
        case .modelNotReady: "clock.arrow.circlepath"
        case .emptyTranscript: "mic.slash"
        case .contextOverflow: "doc.text.magnifyingglass"
        }
    }

    private var title: String {
        switch failure {
        case .deviceNotEligible: "This iPhone can't run Notes Organizer"
        case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence"
        case .modelNotReady: "The model isn't ready yet"
        case .emptyTranscript: "We didn't catch anything"
        case .contextOverflow: "That note is too long"
        }
    }

    private var message: String {
        switch failure {
        case .deviceNotEligible:
            "Organizing runs entirely on your iPhone, which needs Apple Intelligence — iPhone 15 Pro or later."
        case .appleIntelligenceNotEnabled:
            "Notes Organizer uses Apple Intelligence on your iPhone to organize notes. Turn it on in Settings, then come back."
        case .modelNotReady(let reason):
            reason
        case .emptyTranscript:
            "There wasn't enough there to organize. Record again and speak for a few seconds."
        case .contextOverflow:
            "This one is long enough that it won't fit in a single pass. Try splitting it into two notes."
        }
    }
}

#Preview("Not enabled") {
    UnavailableView(failure: .appleIntelligenceNotEnabled)
}

#Preview("Empty transcript") {
    UnavailableView(failure: .emptyTranscript, onRetry: {})
}
