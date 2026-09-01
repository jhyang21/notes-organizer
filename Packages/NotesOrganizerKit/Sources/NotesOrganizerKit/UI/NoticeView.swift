import SwiftUI

/// One layout for every "here is why there's no note" screen: a large muted
/// symbol, a headline, an explanation, and whatever way forward the caller
/// can offer. The app, the share extension, and `UnavailableView` all use it,
/// so a dead end looks the same wherever the user hits one.
public struct NoticeView<Actions: View>: View {
    private let symbol: String
    private let title: String
    private let message: String
    private let actions: Actions

    // The one large fixed size in this view; everything else is already
    // system type, which scales on its own.
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 48

    public init(
        symbol: String,
        title: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        // Sized to at least the available space: short content still
        // centers the way it always has, and a dead end taller than the
        // screen at accessibility text sizes — the quota wall and the
        // paywall hint especially — scrolls instead of clipping.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 16) {
                        Image(systemName: symbol)
                            .font(.system(size: symbolSize))
                            .foregroundStyle(.secondary)

                        Text(title)
                            .font(.headline)
                            .multilineTextAlignment(.center)

                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    // One VoiceOver stop for "what happened and why," not
                    // three — the actions below stay their own elements.
                    .accessibilityElement(children: .combine)

                    actions
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }
}

public extension NoticeView where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

#Preview("No action") {
    NoticeView(
        symbol: "doc.text",
        title: "There's no text here",
        message: "Select the text you want organized, then share it again."
    )
}

#Preview("With action") {
    NoticeView(
        symbol: "exclamationmark.triangle",
        title: "Recording failed",
        message: "Something interrupted the microphone."
    ) {
        Button("Try again") {}
            .buttonStyle(.borderedProminent)
    }
}
