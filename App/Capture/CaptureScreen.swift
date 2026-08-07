import NotesOrganizerKit
import SwiftUI

/// The single-screen capture flow: idle → recording → organizing → a
/// simple note display, replacing the M0 placeholder. Real preview/save UI
/// (contact-free here — just title/sections/action items) with save/share
/// actions lands in M5; this is enough to exercise the pipeline end to end
/// from TestFlight for M4's exit criteria.
struct CaptureScreen: View {
    @State private var viewModel = CaptureViewModel()

    var body: some View {
        VStack(spacing: 24) {
            switch viewModel.state {
            case .idle:
                idleView
            case .requestingPermissions:
                statusView(message: "Requesting microphone access…")
            case .downloadingAssets(let progress):
                downloadingView(progress: progress)
            case .recording(let liveTranscript, let level, let elapsed):
                recordingView(liveTranscript: liveTranscript, level: level, elapsed: elapsed)
            case .organizing:
                statusView(message: "Organizing your note…")
            case .preview(let note):
                previewView(note: note)
            case .saved:
                savedView
            case .failed(let failure):
                failedView(failure: failure)
            }
        }
        .padding()
        .animation(.default, value: viewModel.state)
    }

    // MARK: - States

    private var idleView: some View {
        VStack(spacing: 24) {
            Text("Notes Organizer")
                .font(.largeTitle.bold())

            Button {
                viewModel.startCapture()
            } label: {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 72))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start recording")

            Text("Tap to start talking. We'll turn it into an organized note.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func statusView(message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private func downloadingView(progress: Double) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: progress)
                .frame(width: 200)
            Text("Downloading on-device speech model…")
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func recordingView(liveTranscript: String, level: Float, elapsed: Duration) -> some View {
        VStack(spacing: 24) {
            RecordingIndicatorView(level: level, elapsed: elapsed)

            ScrollView {
                Text(liveTranscript.isEmpty ? "Listening…" : liveTranscript)
                    .font(.body)
                    .foregroundStyle(liveTranscript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)

            Text("Recording stops automatically after a pause, or after 5 minutes.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Button("Stop", role: .destructive) {
                viewModel.stopRecording()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func previewView(note: OrganizedNote) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(note.title.isEmpty ? "Untitled note" : note.title)
                    .font(.title2.bold())

                ForEach(Array(note.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 6) {
                        if !section.heading.isEmpty {
                            Text(section.heading)
                                .font(.headline)
                        }
                        ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                            Label(bullet, systemImage: "circle.fill")
                                .imageScale(.small)
                                .font(.body)
                        }
                    }
                }

                if !note.actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Action items")
                            .font(.headline)
                        ForEach(Array(note.actionItems.enumerated()), id: \.offset) { _, item in
                            Label(item, systemImage: "checkmark.circle")
                                .imageScale(.small)
                                .font(.body)
                        }
                    }
                }

                Button("Record again") {
                    viewModel.reset()
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private var savedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Saved")
                .font(.headline)
        }
    }

    private func failedView(failure: CaptureFailure) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text(failure.title)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(failure.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Try again") {
                viewModel.reset()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private extension CaptureFailure {
    var title: String {
        switch self {
        case .microphonePermissionDenied: "Microphone access needed"
        case .assetsUnsupported: "Speech model unavailable"
        case .assetDownloadFailed: "Couldn't download speech model"
        case .captureFailed: "Recording failed"
        case .emptyRecording: "We didn't catch anything"
        case .organizeFailed: "Couldn't organize that note"
        }
    }

    var message: String {
        switch self {
        case .microphonePermissionDenied:
            "Notes Organizer needs microphone access to transcribe your voice. Enable it in Settings."
        case .assetsUnsupported:
            "This device doesn't support on-device speech transcription in this language."
        case .assetDownloadFailed(let reason):
            reason
        case .captureFailed(let reason):
            reason
        case .emptyRecording:
            "Try again and speak for a moment before stopping."
        case .organizeFailed(let failure):
            failure.message
        }
    }
}

private extension OrganizeFailure {
    var message: String {
        switch self {
        case .deviceNotEligible:
            "This device doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence in Settings to organize notes."
        case .modelNotReady(let reason):
            reason
        case .emptyTranscript:
            "There was nothing to organize."
        case .contextOverflow:
            "That recording was too long to organize in one pass."
        case .overSummarized:
            "The organized note lost too much detail. Try again."
        }
    }
}

#Preview {
    CaptureScreen()
}
