import Testing
@testable import NotesOrganizerKit

@Suite("DeterministicFormatter")
struct DeterministicFormatterTests {
    @Test("splits a spoken paragraph into one bullet per sentence")
    func splitsSentencesIntoBullets() {
        let note = DeterministicFormatter.format("Call the dentist tomorrow. Pick up dry cleaning.")

        #expect(note.sections.count == 1)
        #expect(note.sections[0].heading.isEmpty)
        #expect(note.sections[0].bullets == ["Call the dentist tomorrow.", "Pick up dry cleaning."])
    }

    @Test("makes one section per paragraph")
    func onePerParagraph() {
        let note = DeterministicFormatter.format("First thought.\n\nSecond thought. Still second.")

        #expect(note.sections.count == 2)
        #expect(note.sections[0].bullets == ["First thought."])
        #expect(note.sections[1].bullets == ["Second thought.", "Still second."])
    }

    @Test("treats an already-listed paragraph as one bullet per line")
    func oneBulletPerLine() {
        let note = DeterministicFormatter.format("Milk\nEggs\nBread")

        #expect(note.sections.count == 1)
        #expect(note.sections[0].bullets == ["Milk", "Eggs", "Bread"])
    }

    @Test("titles the note from its first sentence, without the trailing stop")
    func titlesFromFirstSentence() {
        let note = DeterministicFormatter.format("Kitchen renovation quotes. Bosch quoted 4200 for cabinets.")

        #expect(note.title == "Kitchen renovation quotes")
    }

    @Test("caps a long title at a word boundary")
    func capsLongTitle() {
        let long = Array(repeating: "word", count: 40).joined(separator: " ")
        let note = DeterministicFormatter.format(long)

        #expect(note.title.count <= DeterministicFormatter.maxTitleLength)
        #expect(!note.title.hasSuffix(" "))
        #expect(long.hasPrefix(note.title))
    }

    @Test("never invents action items")
    func neverInventsActionItems() {
        let note = DeterministicFormatter.format("I need to call the bank tomorrow, don't forget.")

        #expect(note.actionItems.isEmpty)
    }

    @Test("keeps every word of the input — the whole point of the fallback")
    func losesNothing() {
        let input = """
        So I talked to Marcus about the Q3 numbers and he said 41,000 units. \
        Also the Berlin office wants a call next Tuesday.

        Separately, remind me to send Priya the deck before Friday.
        """

        let note = DeterministicFormatter.format(input)

        let bulletWords = note.sections
            .flatMap(\.bullets)
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let inputWords = input.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        #expect(bulletWords == inputWords)
    }

    @Test("survives an empty or whitespace-only input")
    func handlesEmptyInput() {
        #expect(DeterministicFormatter.format("") == OrganizedNote())
        #expect(DeterministicFormatter.format("   \n\n  ") == OrganizedNote())
    }

    @Test("is deterministic — same text in, same note out")
    func isDeterministic() {
        let input = "One thing happened. Then another thing happened."

        #expect(DeterministicFormatter.format(input) == DeterministicFormatter.format(input))
    }
}
