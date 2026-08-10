import Foundation
import Testing
@testable import NotesOrganizerKit

/// The sweep runs over a directory the whole system writes to, so what it
/// deletes matters more than what it keeps.
@Suite("RecordingFile")
struct RecordingFileTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func file(_ name: String, ageInHours: Double) -> RecordingFile {
        RecordingFile(name: name, modifiedAt: now.addingTimeInterval(-ageInHours * 3600))
    }

    @Test("a new name carries the prefix a sweep looks for, and is never the same twice")
    func namesAreOursAndUnique() {
        let name = RecordingFile.newName()
        #expect(name.hasPrefix("capture-"))
        #expect(name.hasSuffix(".m4a"))
        #expect(RecordingFile.isRecording(name))
        #expect(RecordingFile.newName() != RecordingFile.newName())
    }

    @Test("only TidyNote's own leftovers are recognized")
    func recognizesOnlyOurFiles() {
        #expect(RecordingFile.isRecording("capture-\(UUID().uuidString).m4a"))
        #expect(!RecordingFile.isRecording("capture-\(UUID().uuidString).mp3"))
        #expect(!RecordingFile.isRecording("someone-elses.m4a"))
        #expect(!RecordingFile.isRecording("capture.m4a"))
    }

    @Test("a sweep takes the old recordings and leaves everything else alone")
    func sweepsOnlyStaleRecordings() {
        let stale = file(RecordingFile.newName(), ageInHours: 25)
        let fresh = file(RecordingFile.newName(), ageInHours: 3)
        let someoneElses = file("com.apple.something.tmp", ageInHours: 900)

        let swept = RecordingFile.stale(among: [stale, fresh, someoneElses], now: now)

        #expect(swept == [stale])
    }

    @Test("a recording right on the age limit is kept, one past it isn't")
    func boundaryIsExclusive() {
        let onTheLimit = RecordingFile(
            name: RecordingFile.newName(),
            modifiedAt: now.addingTimeInterval(-RecordingFile.maximumAge)
        )
        let justPast = RecordingFile(
            name: RecordingFile.newName(),
            modifiedAt: now.addingTimeInterval(-RecordingFile.maximumAge - 1)
        )

        #expect(RecordingFile.stale(among: [onTheLimit, justPast], now: now) == [justPast])
    }

    @Test("a file dated in the future is left where it is")
    func toleratesAClockThatWentBackwards() {
        let fromTheFuture = file(RecordingFile.newName(), ageInHours: -48)
        #expect(RecordingFile.stale(among: [fromTheFuture], now: now).isEmpty)
    }
}
