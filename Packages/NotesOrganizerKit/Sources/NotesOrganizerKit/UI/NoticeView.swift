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
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            actions
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
