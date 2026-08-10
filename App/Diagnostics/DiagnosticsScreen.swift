import NotesOrganizerKit
import SwiftUI

/// A workbench, not a feature. It answers the questions a Windows machine
/// can't: how long a real tidy took on this iPhone, what Apple Notes actually
/// hands the share extension, and whether Notes' Markdown import keeps a
/// note's structure. It ships in the beta on purpose — the answers only exist
/// on Andrew's device.
struct DiagnosticsScreen: View {
    @State private var viewModel = DiagnosticsViewModel()

    var body: some View {
        List {
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

    // MARK: - 1. Markdown import check

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

    // MARK: - 2. Share payloads

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

    // MARK: - 3. Organize timings

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

    // MARK: - 4. Device

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
