import Foundation
import Testing
@testable import NotesOrganizerKit

@Suite("NoteShareItem")
struct NoteShareItemTests {
    private let note = OrganizedNote(
        title: "Kitchen Renovation Notes",
        sections: [NoteSection(heading: "Quotes", bullets: ["Bosch quoted 4,200 for cabinets"])],
        actionItems: ["Call the contractor back on Thursday"]
    )

    /// Each test gets its own directory under `tmp`, so nothing here can see
    /// or delete another test's files.
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteShareItemTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("writes a .md file named after the note title")
    func writesMarkdownFile() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try NoteShareItem.makeMarkdownFile(for: note, in: directory)

        #expect(url.pathExtension == "md")
        #expect(url.deletingPathExtension().lastPathComponent == "Kitchen Renovation Notes")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("writes exactly the Markdown renderer's output")
    func writesRenderedMarkdown() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try NoteShareItem.makeMarkdownFile(for: note, in: directory)
        let written = try String(contentsOf: url, encoding: .utf8)

        #expect(written == MarkdownRenderer.render(note))
    }

    @Test("creates the directory when it doesn't exist yet")
    func createsDirectory() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        _ = try NoteShareItem.makeMarkdownFile(for: note, in: directory)

        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("sanitizes a hostile title into a usable filename")
    func sanitizesTitle() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try NoteShareItem.makeMarkdownFile(for: OrganizedNote(title: "Q3/Q4: plan?"), in: directory)

        #expect(url.lastPathComponent == "Q3 Q4 plan.md")
    }

    @Test("re-sharing the same note overwrites rather than piling up copies")
    func overwritesSameNote() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try NoteShareItem.makeMarkdownFile(for: note, in: directory)
        let second = try NoteShareItem.makeMarkdownFile(for: note, in: directory)

        #expect(first == second)
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.count == 1)
    }

    @Test("removes files older than the cutoff and keeps fresh ones")
    func removesStaleFiles() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let stale = try NoteShareItem.makeMarkdownFile(for: OrganizedNote(title: "Old"), in: directory)
        let fresh = try NoteShareItem.makeMarkdownFile(for: OrganizedNote(title: "New"), in: directory)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -600)],
            ofItemAtPath: stale.path
        )

        NoteShareItem.removeStaleFiles(olderThan: 60, in: directory)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test("shrugs off a directory that isn't there")
    func toleratesMissingDirectory() {
        NoteShareItem.removeStaleFiles(in: makeDirectory())
    }
}
