import SwiftUI

/// Minimal level meter: a system-colored circle that scales with the
/// normalized (0...1) audio level, plus the elapsed recording time. No
/// custom brand yet, per the plan — system colors and SF Symbols only.
struct RecordingIndicatorView: View {
    let level: Float
    let elapsed: Duration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ScaledMetric(relativeTo: .largeTitle) private var circleSize: CGFloat = 120
    @ScaledMetric(relativeTo: .largeTitle) private var containerSize: CGFloat = 160
    @ScaledMetric(relativeTo: .largeTitle) private var waveformSize: CGFloat = 40

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
                    .frame(width: circleSize, height: circleSize)
                    .scaleEffect(scale)
                    .animation(.easeOut(duration: 0.12), value: level)

                Image(systemName: "waveform")
                    .font(.system(size: waveformSize, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
            }
            .frame(width: containerSize, height: containerSize)

            Text(elapsedLabel)
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        // One element for the whole indicator: a VoiceOver user doesn't need
        // to visit the pulsing circle and the clock separately, and the
        // pulse fires many times a second, so it needs to stay out of the
        // rotor entirely rather than compete with everything else on screen.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording")
        .accessibilityValue(elapsed.formatted(.units(allowed: [.minutes, .seconds], width: .wide)))
        .accessibilityAddTraits(.updatesFrequently)
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
