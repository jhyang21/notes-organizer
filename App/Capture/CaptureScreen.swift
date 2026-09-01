import NotesOrganizerKit
import SwiftUI
import UIKit

/// The single-screen capture flow: idle → recording → sending → preview.
/// The preview, save actions, and unavailable states are all
/// `NotesOrganizerKit` views, so the share extension shows the user the same
/// screens the app does.
struct CaptureScreen: View {
    @State private var viewModel: CaptureViewModel
    @State private var isShowingPaywall = false
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

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
                case .recording(let level, let elapsed):
                    recordingView(level: level, elapsed: elapsed)
                case .uploading:
                    sendingView(message: "Sending your recording…")
                case .organizing:
                    sendingView(message: "Turning it into a note…")
                case .readyToSend(let duration):
                    readyToSendView(duration: duration)
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
        .onAppear {
            // The draft first: it can only be there because a note was made,
            // which means the first-run question was answered long ago.
            viewModel.restoreDraftIfAvailable()
            viewModel.showFirstRunIfNeeded()
        }
        // A recording outlives the screen it started on — the audio background
        // mode sees to that. `.inactive` is skipped, and the view model's
        // foreground test agrees: a notification banner pulled over the app is
        // not the app going away, and a recording that ends under one should
        // upload like any other.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: viewModel.appBecameActive()
            case .background: viewModel.appWentToBackground()
            default: break
            }
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

    /// Both halves of the wait, which look the same to the user and read
    /// differently on purpose: the caption is the honest part, since a long
    /// recording spends most of the wait on a server we can't see into.
    private func sendingView(message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Long recordings can take up to a minute.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            // Leaving the wait must not mean leaving the recording, so this
            // is the only button here and it isn't the loud kind.
            Button("Cancel") {
                viewModel.cancelTidy()
            }
            .buttonStyle(.bordered)
        }
    }

    /// Where a cancelled tidy waits. Nothing was lost by cancelling — the
    /// screen's job is to say so and offer the send again.
    private func readyToSendView(duration: TimeInterval) -> some View {
        VStack(spacing: 24) {
            Text("Your recording is ready")
                .font(.headline)

            Text("Recording saved — \(durationLabel(duration)).")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                Button("Send") {
                    viewModel.send()
                }
                .buttonStyle(.borderedProminent)

                Button("Start Over") {
                    viewModel.reset()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// "7 seconds", "1 minute, 12 seconds" — the formatter handles the plural
    /// and the units in whatever language the phone is in.
    private func durationLabel(_ duration: TimeInterval) -> String {
        Duration.seconds(duration.rounded())
            .formatted(.units(allowed: [.minutes, .seconds], width: .wide))
    }

    private func recordingView(level: Float, elapsed: Duration) -> some View {
        VStack(spacing: 24) {
            RecordingIndicatorView(level: level, elapsed: elapsed)

            Text("We'll transcribe when you stop.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

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
            // A refused microphone can't be un-refused from in here, so
            // "Try again" would be a button that provably can't work. The
            // only honest one goes where the answer can be changed.
            if failure == .microphonePermissionDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Try again") {
                    viewModel.reset()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

private extension CaptureFailure {
    var title: String {
        switch self {
        case .microphonePermissionDenied: "Microphone access needed"
        case .captureFailed: "Recording failed"
        case .emptyRecording: "Nothing to tidy"
        }
    }

    var message: String {
        switch self {
        case .microphonePermissionDenied:
            "TidyNote needs the microphone to record what you say. Turn it on in Settings."
        case .captureFailed(let reason):
            reason
        case .emptyRecording:
            "We didn't hear anything. Try again and speak for a few seconds."
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
