import Foundation
import Testing
@testable import NotesOrganizerKit

/// Cancellation, which `MockOrganizer` can't express — it only throws
/// `OrganizeFailure`.
private struct CancellingOrganizer: NoteOrganizing {
    func organize(_ text: String) async throws -> OrganizedNote {
        throw CancellationError()
    }
}

@Suite("OrganizerRouter")
struct OrganizerRouterTests {
    private let cloudNote = OrganizedNote(title: "From the cloud", sections: [NoteSection(heading: "H", bullets: ["b"])])
    private let onDeviceNote = OrganizedNote(title: "From this iPhone", sections: [NoteSection(heading: "H", bullets: ["b"])])

    private func makeLog() -> DiagnosticsLog {
        DiagnosticsLog(storage: InMemoryDiagnosticsStorage())
    }

    private func makeRouter(
        route: RoutingPolicy.Route,
        cloud: NoteOrganizing,
        onDevice: NoteOrganizing,
        log: DiagnosticsLog
    ) -> OrganizerRouter {
        OrganizerRouter(route: route, cloud: cloud, onDevice: onDevice, source: .app, log: log)
    }

    // MARK: - Running the route

    @Test("an on-device route never touches the cloud")
    func onDeviceRouteStaysLocal() async throws {
        let cloud = MockOrganizer(result: cloudNote)
        let onDevice = MockOrganizer(result: onDeviceNote)
        let router = makeRouter(route: .onDevice, cloud: cloud, onDevice: onDevice, log: makeLog())

        let note = try await router.organize("some text to organize")
        #expect(note == onDeviceNote)
        #expect(await cloud.receivedTranscripts.isEmpty)
    }

    @Test("a cloud route that works never runs the on-device model")
    func cloudRouteSucceeds() async throws {
        let cloud = MockOrganizer(result: cloudNote)
        let onDevice = MockOrganizer(result: onDeviceNote)
        let router = makeRouter(route: .cloud(fallbackOnDevice: true), cloud: cloud, onDevice: onDevice, log: makeLog())

        let note = try await router.organize("some text to organize")
        #expect(note == cloudNote)
        #expect(await onDevice.receivedTranscripts.isEmpty)
    }

    // MARK: - Fallback

    @Test("a Pro user offline gets the on-device note, and the fallback is logged")
    func fallsBackWhenAllowed() async throws {
        let log = makeLog()
        let cloud = MockOrganizer(error: .networkUnavailable)
        let onDevice = MockOrganizer(result: onDeviceNote)
        let router = makeRouter(route: .cloud(fallbackOnDevice: true), cloud: cloud, onDevice: onDevice, log: log)

        let note = try await router.organize("some text to organize")
        #expect(note == onDeviceNote)
        #expect(await onDevice.receivedTranscripts == ["some text to organize"])
        #expect(log.events().count == 1)
    }

    @Test("an explicit premium tidy surfaces its failure instead of downgrading")
    func forceCloudSurfacesFailures() async throws {
        let log = makeLog()
        let cloud = MockOrganizer(error: .cloudUnavailable(reason: "The service is busy right now."))
        let onDevice = MockOrganizer(result: onDeviceNote)
        let router = makeRouter(route: .cloud(fallbackOnDevice: false), cloud: cloud, onDevice: onDevice, log: log)

        await #expect(throws: OrganizeFailure.cloudUnavailable(reason: "The service is busy right now.")) {
            try await router.organize("some text to organize")
        }
        #expect(await onDevice.receivedTranscripts.isEmpty)
        #expect(log.events().isEmpty)
    }

    @Test("cancelling a cloud run doesn't quietly start an on-device one")
    func cancellationDoesNotFallBack() async throws {
        let cloud = CancellingOrganizer()
        let onDevice = MockOrganizer(result: onDeviceNote)
        let router = makeRouter(route: .cloud(fallbackOnDevice: true), cloud: cloud, onDevice: onDevice, log: makeLog())

        await #expect(throws: CancellationError.self) {
            try await router.organize("some text to organize")
        }
        #expect(await onDevice.receivedTranscripts.isEmpty)
    }

    // MARK: - Routes that run nothing

    @Test("the quota wall throws without asking either organizer")
    func blockedRouteRunsNothing() async throws {
        let cloud = MockOrganizer(result: cloudNote)
        let onDevice = MockOrganizer(result: onDeviceNote)
        let router = makeRouter(
            route: .blocked(.cloudQuotaExhausted),
            cloud: cloud,
            onDevice: onDevice,
            log: makeLog()
        )

        await #expect(throws: OrganizeFailure.cloudQuotaExhausted) {
            try await router.organize("some text to organize")
        }
        #expect(await cloud.receivedTranscripts.isEmpty)
        #expect(await onDevice.receivedTranscripts.isEmpty)
    }

    @Test("a route waiting on consent sends nothing anywhere")
    func consentNeededRunsNothing() async throws {
        let log = makeLog()
        let cloud = MockOrganizer(result: cloudNote)
        let onDevice = MockOrganizer(result: onDeviceNote)
        let router = makeRouter(route: .consentNeeded, cloud: cloud, onDevice: onDevice, log: log)

        await #expect(throws: OrganizeFailure.cloudConsentNeeded) {
            try await router.organize("some text to organize")
        }
        #expect(await cloud.receivedTranscripts.isEmpty)
        #expect(await onDevice.receivedTranscripts.isEmpty)
        #expect(log.events().count == 1)
    }
}
