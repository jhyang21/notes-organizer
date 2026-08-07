import Foundation
import Speech

/// Where the on-device speech model is for a given locale, for the UI to
/// react to (spinner vs. progress bar vs. an unsupported-device message).
enum SpeechAssetStatus: Equatable, Sendable {
    case checking
    case unsupported
    case needsDownload
    case downloading(progress: Double)
    case ready
    case failed(String)
}

/// Checks whether `SpeechTranscriber`'s on-device assets for a locale are
/// installed, and drives `AssetInventory`'s installation request when
/// they're not, reporting every status transition through `onStatusChange`
/// so a caller (namely `CaptureViewModel`) can mirror it into its own state
/// machine without polling. App-target only, like the rest of
/// `App/Transcription` — nothing here runs against a real model on CI.
@MainActor
final class SpeechAssetManager {
    private(set) var status: SpeechAssetStatus = .checking

    /// Resolves once the locale is confirmed `.ready`, or throws
    /// `SpeechAssetError` once it lands on `.unsupported`/`.failed`.
    /// `onStatusChange` fires for every transition, including the final one,
    /// before this returns/throws — callers that only care about the
    /// terminal outcome can ignore it and just inspect the result.
    func ensureAssets(
        for locale: Locale,
        transcriber: SpeechTranscriber,
        onStatusChange: (SpeechAssetStatus) -> Void = { _ in }
    ) async throws {
        func update(_ next: SpeechAssetStatus) {
            status = next
            onStatusChange(next)
        }

        update(.checking)

        let supportedLocales = await SpeechTranscriber.supportedLocales
        guard supportedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            update(.unsupported)
            throw SpeechAssetError.unsupported
        }

        let installedLocales = await SpeechTranscriber.installedLocales
        if installedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            update(.ready)
            return
        }

        update(.needsDownload)
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                // Nothing to install — the SDK already considers this
                // locale ready even though it wasn't in `installedLocales`.
                update(.ready)
                return
            }

            let progressObservation = request.progress.observe(\.fractionCompleted) { progress, _ in
                Task { @MainActor in
                    update(.downloading(progress: progress.fractionCompleted))
                }
            }
            defer { progressObservation.invalidate() }

            try await request.downloadAndInstall()
            update(.ready)
        } catch {
            update(.failed(error.localizedDescription))
            throw SpeechAssetError.installFailed(error.localizedDescription)
        }
    }
}

enum SpeechAssetError: Error, Equatable {
    case unsupported
    case installFailed(String)
}
