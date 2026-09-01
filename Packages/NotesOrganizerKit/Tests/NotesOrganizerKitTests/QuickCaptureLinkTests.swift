import Foundation
import Testing
@testable import NotesOrganizerKit

@Suite("QuickCaptureLink")
struct QuickCaptureLinkTests {
    /// The one test the force-unwrap in `url` rests on. A case whose name
    /// didn't survive `URL(string:)` would crash a widget tap on a device; here
    /// it fails a build instead.
    @Test("every case builds the URL its name spells out", arguments: QuickCaptureLink.allCases)
    func everyCaseBuildsItsURL(link: QuickCaptureLink) {
        #expect(link.url.absoluteString == "tidynote://\(link.rawValue)")
    }

    @Test("a link the app built reads back as the same link", arguments: QuickCaptureLink.allCases)
    func routingIsTheInverseOfBuilding(link: QuickCaptureLink) {
        #expect(QuickCaptureLink.route(link.url) == link)
    }

    @Test("the scheme is matched however it is typed")
    func schemeIsCaseInsensitive() throws {
        let url = try #require(URL(string: "TidyNote://Record"))

        #expect(QuickCaptureLink.route(url) == .record)
    }

    /// What a hand-typed link looks like: the target lands in the path rather
    /// than the host, and means the same thing.
    @Test("a target in the path routes like a target in the host")
    func targetInPathRoutes() throws {
        let url = try #require(URL(string: "tidynote:///paywall"))

        #expect(QuickCaptureLink.route(url) == .paywall)
    }

    @Test(
        "a URL asking for nothing this version knows routes nowhere",
        arguments: [
            "tidynote://",
            "tidynote://somethingelse",
            "https://example.com/record",
            "notes://record"
        ]
    )
    func unknownURLsRouteNowhere(string: String) throws {
        let url = try #require(URL(string: string))

        #expect(QuickCaptureLink.route(url) == nil)
    }
}
