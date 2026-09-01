import SwiftUI

/// Minimal level meter: a system-colored circle that scales with the
/// normalized (0...1) audio level, plus the elapsed recording time. No
/// custom brand yet, per the plan — system colors and SF Symbols only.
struct RecordingIndicatorView: View {
    let level: Float
    let elapsed: Duration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Reduce Motion turns the pulse off rather than just unanimating it — a
    // circle that still jumps to a new size on every meter sample is motion
    // by another name.
    private var scale: CGFloat {
        guard !reduceMotion else { return 1.0 }
        return 1.0 + CGFloat(min(max(level, 0), 1)) * 0.5
    }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 120, height: 120)
                    .scaleEffect(scale)
                    .animation(.easeOut(duration: 0.12), value: level)

                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
            }
            .frame(width: 160, height: 160)

            Text(elapsedLabel)
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var elapsedLabel: String {
        let totalSeconds = Int(elapsed.components.seconds)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    RecordingIndicatorView(level: 0.4, elapsed: .seconds(37))
}
