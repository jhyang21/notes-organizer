import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The real organizer: Apple's on-device language model, wrapped so callers
/// only ever see `OrganizedNote` and `OrganizeFailure`.
///
/// Nothing here runs in CI. The unit suite exercises the pure pieces this
/// type composes — `TranscriptChunker`, `NoteMerger`, `OutputSanitizer`,
/// `OverSummarizationPolicy` — and `MockOrganizer` stands in for the whole
/// type wherever a `NoteOrganizing` is needed.
///
/// The one rule that shapes every branch below: **the user never loses
/// content.** There is no mechanical formatting floor. When the model
/// refuses the text, returns something undecodable, or still summarizes
/// after the one retry, this throws `.onDeviceFailed` and leaves the
/// transcript whole in the caller's hands — a note that dropped half the
/// words would be worse than no note. The recovery the user is offered is a
/// premium tidy, not a lesser one.
public struct FoundationModelOrganizer: NoteOrganizing {
    /// Two estimators, because the chunker's inner loop is synchronous and
    /// the model's own tokenizer is not: `tokenEstimator` drives chunking,
    /// `asyncEstimator` answers the one question worth a precise answer —
    /// does this transcript fit in a single call?
    private let tokenEstimator: TokenEstimating
    private let asyncEstimator: AsyncTokenEstimating

    public init() {
        #if canImport(FoundationModels)
        self.init(tokenEstimator: HeuristicTokenEstimator(), asyncEstimator: SystemTokenEstimator())
        #else
        self.init(tokenEstimator: HeuristicTokenEstimator(), asyncEstimator: HeuristicTokenEstimator())
        #endif
    }

    init(tokenEstimator: TokenEstimating, asyncEstimator: AsyncTokenEstimating) {
        self.tokenEstimator = tokenEstimator
        self.asyncEstimator = asyncEstimator
    }

    public func organize(_ text: String) async throws -> OrganizedNote {
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MeaningfulText.isWorthOrganizing(transcript) else {
            throw OrganizeFailure.emptyTranscript
        }

        if let failure = await ModelAvailability.currentFailure() {
            throw failure
        }

        #if canImport(FoundationModels)
        do {
            return try await organize(transcript, budget: .default)
        } catch let failure as OrganizeFailure {
            // The model rejected a chunk the estimate said would fit. Re-cut
            // the transcript smaller and try once more; a second overflow is
            // a real failure.
            guard case .contextOverflow = failure else { throw failure }
            return try await organize(transcript, budget: .reduced)
        }
        #else
        // Unreachable in practice — `ModelAvailability` reports
        // `.deviceNotEligible` above on a build with no FoundationModels.
        throw OrganizeFailure.deviceNotEligible
        #endif
    }
}

#if canImport(FoundationModels)

extension FoundationModelOrganizer {
    // MARK: - Routing

    private func organize(_ transcript: String, budget: TranscriptChunker.Budget) async throws -> OrganizedNote {
        if await asyncEstimator.estimatedTokenCount(transcript) <= budget.hardCeilingTokens {
            return try await organizeSingleCall(transcript)
        }
        return try await organizeChunked(transcript, budget: budget)
    }

    // MARK: - Single call

    /// One fresh session, one response, then the over-summarization guard:
    /// accept, re-ask once with the retry instructions, or give up.
    private func organizeSingleCall(_ transcript: String) async throws -> OrganizedNote {
        var attempt = 0
        var instructions = OrganizerPrompt.instructions

        while true {
            let note = OutputSanitizer.sanitize(try await generateNote(from: transcript, instructions: instructions))
            switch OverSummarizationPolicy.decide(input: transcript, output: note, attempt: attempt) {
            case .accept:
                return note
            case .retry:
                attempt += 1
                instructions = OrganizerPrompt.instructions + "\n\n" + OrganizerPrompt.retrySuffix
            case .reject:
                throw OrganizeFailure.onDeviceFailed
            }
        }
    }

    // MARK: - Chunked

    /// One fresh session per chunk — the 4k context can't hold a long
    /// transcript, and a session that carries earlier chunks forward would
    /// start summarizing them. `NoteMerger` recombines deterministically;
    /// only the title gets a (best-effort) model pass afterwards.
    private func organizeChunked(_ transcript: String, budget: TranscriptChunker.Budget) async throws -> OrganizedNote {
        let chunks = TranscriptChunker(tokenEstimator: tokenEstimator, budget: budget).chunk(transcript)
        guard !chunks.isEmpty else { throw OrganizeFailure.emptyTranscript }

        var notes: [OrganizedNote] = []
        notes.reserveCapacity(chunks.count)
        for chunk in chunks {
            notes.append(try await organizeSingleCall(chunk))
        }

        var merged = NoteMerger.merge(notes)
        if let refined = await refinedTitle(for: merged, chunkTitles: notes.map(\.title)) {
            merged.title = refined
        }
        return OutputSanitizer.sanitize(merged)
    }

    /// A micro-call over the merged note's headings to name the note as a
    /// whole — a title stitched from chunk one alone usually describes only
    /// its first minute. Best effort: any failure keeps the merger's title.
    private func refinedTitle(for note: OrganizedNote, chunkTitles: [String]) async -> String? {
        let headings = note.sections.map(\.heading).filter { !$0.isEmpty }
        let candidates = (chunkTitles + headings)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }

        let prompt = """
        These are the section headings and partial titles of one note:
        \(candidates.map { "- \($0)" }.joined(separator: "\n"))

        Write one short title, 3 to 8 words, for the note as a whole.
        """

        let instructions = """
        You name notes. Given the headings of a single note, write one short, \
        specific title that covers all of them. Use only words and topics that \
        appear in the headings; never invent a subject that isn't there.
        """

        guard let response = try? await LanguageModelSession(instructions: instructions)
            .respond(to: prompt, generating: NoteTitle.self) else { return nil }

        let title = response.content.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    // MARK: - Model call + error mapping

    /// Maps every `FoundationModels` error onto the app's own failure
    /// vocabulary.
    private func generateNote(from transcript: String, instructions: String) async throws -> OrganizedNote {
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: "<transcript>\(transcript)</transcript>",
                generating: GeneratedNote.self
            )
            return OrganizedNote(response.content)
        } catch let error as LanguageModelSession.GenerationError {
            throw mapped(error, transcript: transcript)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // An unrecognized generation failure says nothing a user could act
            // on, so it reads as the one thing that is true: this iPhone
            // couldn't tidy this text.
            throw OrganizeFailure.onDeviceFailed
        }
    }

    private func mapped(_ error: LanguageModelSession.GenerationError, transcript: String) -> OrganizeFailure {
        switch error {
        case .exceededContextWindowSize:
            return .contextOverflow(estimatedTokenCount: tokenEstimator.tokenCount(transcript))
        case .assetsUnavailable:
            return .modelNotReady(reason: "The on-device model isn't downloaded yet. Try again once it finishes.")
        case .rateLimited:
            return .modelNotReady(reason: "The on-device model is busy. Try again in a moment.")
        default:
            // Guardrail violations, decoding failures, unsupported guides and
            // languages all mean the same thing to this app: no note from the
            // model for this text. The user keeps their transcript and is
            // offered a premium tidy, which is the only thing left that might
            // work on it.
            return .onDeviceFailed
        }
    }
}

#endif
