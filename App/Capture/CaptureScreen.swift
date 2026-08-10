import NotesOrganizerKit
import SwiftUI

/// The single-screen capture flow: idle → recording → organizing → preview.
/// The preview, save actions, and unavailable states are all
/// `NotesOrganizerKit` views, so the share extension shows the user the same
/// screens the app does.
struct CaptureScreen: View {
    @State private var viewModel: CaptureViewModel
    @State private var isShowingPaywall = false

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
                case .failed(let failure):
                    captureFailureView(failure: failure)
                case .unavailable(let failure):
                    UnavailableView(
                        failure: failure,
                        onRetry: { viewModel.retry() },
                        onUpgrade: { isShowingPaywall = true }
                    )
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
                        SettingsScreen()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        .sheet(isPresented: $isShowingPaywall, onDismiss: { viewModel.refreshPlan() }) {
            PaywallScreen()
        }
        // Full screen rather than a sheet: there is nothing behind it to use
        // yet, and nothing to swipe it away for.
        .fullScreenCover(isPresented: $viewModel.isShowingFirstRun) {
            FirstRunScreen(onContinue: { viewModel.acceptFirstRun() })
        }
        .task {
            viewModel.showFirstRunIfNeeded()
        }
    }

    // MARK: - States

    private var idleView: some View {
        VStack(spacing: 24) {
            Text("TidyNote")
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
            Text("Downloading the speech model…")
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

            SaveActionsBar(note: note, source: .app)

            Button("New note") {
                viewModel.reset()
            }
            .font(.subheadline)
        }
    }

    private func captureFailureView(failure: CaptureFailure) -> some View {
        NoticeView(
            symbol: "exclamationmark.triangle",
            title: failure.title,
            message: failure.message
        ) {
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
        }
    }

    var message: String {
        switch self {
        case .microphonePermissionDenied:
            "TidyNote needs microphone access to transcribe your voice. Enable it in Settings."
        case .assetsUnsupported:
            "This device can't transcribe speech in this language."
        case .assetDownloadFailed(let reason):
            reason
        case .captureFailed(let reason):
            reason
        case .emptyRecording:
            "Try again and speak for a moment before stopping."
        }
    }
}

#Preview("Preview state") {
    CaptureScreen(viewModel: CaptureViewModel(routing: OrganizeRouting(
        cloud: MockOrganizer(result: OrganizedNote(
            title: "Kitchen Renovation Notes",
            sections: [NoteSection(heading: "Quotes", bullets: ["Bosch quoted 4,200 for cabinets"])],
            actionItems: ["Call the contractor back on Thursday"]
        ))
    )))
}
