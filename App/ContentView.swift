import SwiftUI

/// M0 placeholder screen. The real capture flow (idle → recording →
/// organizing → preview → saved) lands in M4/M5 — see the plan.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 24) {
            Text("Notes Organizer")
                .font(.largeTitle.bold())

            Button {
                // No-op placeholder. Recording wires up in M4.
            } label: {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 64))
            }
            .buttonStyle(.plain)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
