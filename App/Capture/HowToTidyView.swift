import SwiftUI

/// Apple Notes has no read API, so TidyNote can't reach into an existing note
/// on its own — the share sheet (Notes → Share → Send Copy → TidyNote) is the
/// only path in. This screen teaches that path rather than the app pretending
/// it has another one.
struct HowToTidyView: View {
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var symbolWidth: CGFloat = 28

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    step(
                        symbol: "square.and.arrow.up",
                        text: "In Apple Notes, open the messy note and tap Share."
                    )
                    step(
                        symbol: "doc.on.doc",
                        text: "If the sheet says Collaborate, switch it to Send Copy."
                    )
                    step(
                        symbol: "sparkles",
                        text: "Choose TidyNote. Your note gets organized right there — save the clean copy without leaving Notes."
                    )

                    Text("This works from any app that can share text.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Tidy an Existing Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func step(symbol: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .frame(width: symbolWidth)
                .foregroundStyle(.tint)
            Text(text)
                .font(.body)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    HowToTidyView()
}
