import NotesOrganizerKit
import SwiftUI

/// A workbench, not a feature. It answers the questions a Windows machine
/// can't: is the model there, how slow is it on this iPhone, what does Apple
/// Notes actually hand the share extension, and does Notes' Markdown import
/// keep a note's structure. It ships in the beta on purpose — the answers
/// only exist on Andrew's device.
struct DiagnosticsScreen: View {
    @State private var viewModel = DiagnosticsViewModel()

    var body: some View {
        List {
            modelStatusSection
            sampleRunSection(
                title: "Model hello-world",
                caption: "Organizes a short sample (~80 words).",
                buttonTitle: "Run short sample",
                sample: .short,
                state: viewModel.helloWorld
            )
            sampleRunSection(
                title: "Latency benchmark",
                caption: "Organizes a longer sample (~400 words).",
                buttonTitle: "Run long sample",
                sample: .long,
                state: viewModel.benchmark
            )
            markdownImportSection
            sharePayloadSection
            timingsSection
            eventsSection
            deviceSection
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    viewModel.refresh()
                }
            }
        }
        .task {
            viewModel.refresh()
            viewModel.prepareMarkdownSample()
        }
    }

    // MARK: - 1. Model status

    private var modelStatusSection: some View {
        Section("Model status") {
            switch viewModel.modelStatus {
            case .checking:
                Text("Checking…")
                    .foregroundStyle(.secondary)
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .unavailable(let failure):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Not ready", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text(String(describing: failure))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 2 & 3. Sample runs

    private enum Sample {
        case short
        case long
    }

    private func sampleRunSection(
        title: String,
        caption: String,
        buttonTitle: String,
        sample: Sample,
        state: DiagnosticsViewModel.RunState
    ) -> some View {
        Section(title) {
            Text(caption)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button(buttonTitle) {
                Task {
                    switch sample {
                    case .short: await viewModel.runShortSample()
                    case .long: await viewModel.runLongSample()
                    }
                }
            }
            .disabled(state == .running)

            switch state {
            case .idle:
                EmptyView()
            case .running:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Organizing…")
                        .foregroundStyle(.secondary)
                }
            case .succeeded(let result):
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "%.2f s for %d words", result.seconds, result.wordCount))
                        .font(.body.monospacedDigit())
                    Text(result.title.isEmpty ? "Untitled" : result.title)
                        .font(.footnote)
                    Text("\(result.sectionCount) sections, \(result.actionItemCount) action items")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - 4. Markdown import check

    private var markdownImportSection: some View {
        Section("Markdown import check") {
            if let url = viewModel.markdownSampleURL {
                ShareLink(item: url) {
                    Label("Share sample note", systemImage: "square.and.arrow.up")
                }
                .simultaneousGesture(TapGesture().onEnded {
                    viewModel.recordMarkdownShareTapped()
                })
                Text("Share to Notes, then check the imported note keeps its headings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let error = viewModel.markdownSampleError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                ProgressView()
            }
        }
    }

    // MARK: - 5. Share payloads

    private var sharePayloadSection: some View {
        Section("Share payloads") {
            if viewModel.sharePayloads.isEmpty {
                Text("Share something into TidyNote first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.sharePayloads) { payload in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(timestamp(payload.timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ForEach(Array(payload.providerTypeIdentifiers.enumerated()), id: \.offset) { index, identifiers in
                            Text("Provider \(index + 1): \(identifiers.isEmpty ? "none" : identifiers.joined(separator: ", "))")
                                .font(.footnote)
                        }

                        Text("Loaded: \(payload.chosenIdentifier ?? "nothing") — \(payload.characterCount) characters")
                            .font(.footnote)
                            .foregroundStyle(payload.chosenIdentifier == nil ? .orange : .secondary)
                    }
                }
            }
        }
    }

    // MARK: - 6. Organize timings

    private var timingsSection: some View {
        Section("Organize timings") {
            if viewModel.organizeTimings.isEmpty {
                Text("No runs recorded yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.organizeTimings) { timing in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(timing.source.displayName + " — " + String(format: "%.2f s for %d words", timing.duration, timing.wordCount))
                            .font(.body.monospacedDigit())
                        Text(timestamp(timing.timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Events

    private var eventsSection: some View {
        Section("Events") {
            if viewModel.events.isEmpty {
                Text("Nothing logged yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.events) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(event.source.displayName): \(event.message)")
                            .font(.footnote)
                        Text(timestamp(event.timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Clear log", role: .destructive) {
                    viewModel.clearLog()
                }
            }
        }
    }

    // MARK: - 7. Device

    private var deviceSection: some View {
        Section("Device") {
            LabeledContent("Model", value: viewModel.deviceModelIdentifier)
            LabeledContent("System", value: viewModel.systemVersion)
        }
    }

    private func timestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}

#Preview {
    NavigationStack {
        DiagnosticsScreen()
    }
}
