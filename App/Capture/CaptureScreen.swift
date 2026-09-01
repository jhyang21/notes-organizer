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
    @Environment(PlanModel.self) private var plan
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .animation(reduceMotion ? nil : .default, value: viewModel.state)
            .sensoryFeedback(trigger: viewModel.state, captureFeedback)
            .navigationTitle("TidyNote")
            .navigationBarTitleDisplayMode(.large)
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
        // Back at idle is where the count is on screen, and the tidy that just
        // finished is what changed it. Only this case: the recording states
        // change several times a second.
        .onChange(of: viewModel.state) { _, state in
            if case .idle = state {
                plan.refresh()
            }
        }
    }

    // MARK: - Haptics

    /// One haptic per state change that means something, not one per tick of
    /// the meter: entering `.recording` (from anywhere else) is the only
    /// `.impact`, leaving it for `.uploading` or `.readyToSend` is the "you
    /// said stop and it heard you" `.success` — auto-stop and the hard cap
    /// both route through the same transition, so they get the same feedback.
    /// A note arriving from the organizer is `.success` too.
    private func captureFeedback(
        from old: CaptureViewModel.State,
        to new: CaptureViewModel.State
    ) -> SensoryFeedback? {
        switch (old, new) {
        case (.recording, .recording):
            return nil
        case (.recording, .uploading), (.recording, .readyToSend):
            return .success
        case (_, .recording):
            return .impact
        case (.failed, .failed), (.unavailable, .unavailable):
            return nil
        case (_, .failed), (_, .unavailable):
            return .error
        case (.preview, .preview):
            return nil
        // A cold launch landing straight on a restored draft is the only way
        // to reach .preview from .idle — restoring is not something the user
        // just did, so it gets no haptic.
        case (.idle, .preview):
            return nil
        case (_, .preview):
            return .success
        default:
            return nil
        }
    }

    // MARK: - States

    private var idleView: some View {
        VStack(spacing: 24) {
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

            // Only when there is a real number to say. Pro is unlimited, and a
            // fresh install hasn't heard a count from the server yet; both
            // read as nothing rather than as a guess.
            if let remaining = plan.remaining {
                Group {
                    if remaining == 1 {
                        Text("1 tidy left this month")
                    } else {
                        Text("\(remaining) tidies left this month")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
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

            Button {
                viewModel.stopRecording()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
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
    let plan = PlanModel()

    CaptureScreen(viewModel: CaptureViewModel(routing: OrganizeRouting(
        cloud: MockOrganizer(result: OrganizedNote(
            title: "Kitchen Renovation Notes",
            sections: [NoteSection(heading: "Quotes", bullets: ["Bosch quoted 4,200 for cabinets"])],
            actionItems: ["Call the contractor back on Thursday"]
        ))
    )))
    .environment(plan)
    .environment(PurchasesController(plan: plan))
}
