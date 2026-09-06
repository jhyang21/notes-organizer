import Testing
@testable import NotesOrganizer

@Suite("ConnectivityState")
struct ConnectivityMonitorTests {
    @Test("no answer within the timeout reads as online")
    func unknownResolvesOnline() async {
        let state = ConnectivityState()

        let isOnline = await state.resolved(waitingUpTo: .milliseconds(40))

        #expect(isOnline)
    }

    @Test("a recorded answer resolves at once")
    func recordedAnswerResolvesImmediately() async {
        let state = ConnectivityState()
        state.record(isOnline: false)

        let isOnline = await state.resolved(waitingUpTo: .seconds(2))

        #expect(isOnline == false)
    }

    @Test("a waiter gets the first answer once it arrives")
    func waiterGetsTheFirstAnswer() async throws {
        let state = ConnectivityState()
        let waiter = Task { await state.resolved(waitingUpTo: .seconds(2)) }
        try await Task.sleep(for: .milliseconds(5))

        state.record(isOnline: false)

        #expect(await waiter.value == false)
    }
}
