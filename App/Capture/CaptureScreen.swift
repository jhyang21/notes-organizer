import NotesOrganizerKit
import SwiftUI

/// The single-screen capture flow: idle → recording → organizing →
/// preview → saved. The preview, save actions, and unavailable states are
/// all `NotesOrganizerKit` views, so the share extension (M6) shows the user
/// the same screens the app does.
struct CaptureScreen: View {
    @State private var viewModel: CaptureViewModel

    init(viewModel: CaptureViewModel = CaptureViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.default, value: viewModel.state)
            // An empty inline title keeps the bar out of the way; the capture
            // screen names itself.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        DiagnosticsScreen()
                    } label: {
                        Image(systemName: "stethoscope")
                    }
                    .accessibilityLabel("Diagnostics")
                }
            }
        }
        .task {
            viewModel.checkModelAvailability()
        }
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
        VStack(spacing: 16) {
            OrganizedNotePreviewView(note: note)
                .frame(maxHeight: .infinity)

            SaveActionsBar(note: note)

            Button("New note") {
                viewModel.reset()
            }
            .font(.subheadline)
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

    /// Organizer failures get the package's `UnavailableView`, which owns the
    /// per-reason copy and the right action for each (open Settings, retry,
    /// record again). Everything upstream of the organizer — microphone,
    /// speech assets, the audio pipeline — is app-only, so it keeps its own
    /// view here.
    @ViewBuilder
    private func failedView(failure: CaptureFailure) -> some View {
        if case .organizeFailed(let organizeFailure) = failure {
            UnavailableView(failure: organizeFailure) {
                viewModel.reset()
            }
        } else {
            captureFailureView(failure: failure)
        }
    }

    private func captureFailureView(failure: CaptureFailure) -> some View {
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
            "This device doesn't support on-device transcription in this language."
        case .assetDownloadFailed(let reason):
            reason
        case .captureFailed(let reason):
            reason
        case .emptyRecording:
            "Try again and speak for a moment before stopping."
        case .organizeFailed:
            // Unreachable: `failedView` routes organizer failures to
            // `UnavailableView`, which has copy of its own for each reason.
            "Something went wrong organizing that note."
        }
    }
}

#Preview("Preview state") {
    CaptureScreen(viewModel: CaptureViewModel(organizer: MockOrganizer(result: OrganizedNote(
        title: "Kitchen Renovation Notes",
        sections: [NoteSection(heading: "Quotes", bullets: ["Bosch quoted 4,200 for cabinets"])],
        actionItems: ["Call the contractor back on Thursday"]
    ))))
}
