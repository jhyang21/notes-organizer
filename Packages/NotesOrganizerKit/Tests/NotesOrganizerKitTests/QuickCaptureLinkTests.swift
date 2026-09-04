import Foundation
import Testing
@testable import NotesOrganizerKit

@Suite("QuickCaptureLink")
struct QuickCaptureLinkTests {
    private let token = "3B1F0F0C-3D1B-4E6A-9E3E-6A2B0D5C1A77"

    /// The one test the force-unwrap in `url` rests on. A case whose name
    /// didn't survive `URL(string:)` would crash a widget tap on a device; here
    /// it fails a build instead.
    @Test("every case builds the URL its name spells out", arguments: QuickCaptureLink.allCases)
    func everyCaseBuildsItsURL(link: QuickCaptureLink) {
        #expect(link.url.absoluteString == "tidynote://\(link.rawValue)")
    }

    /// Only `record` starts anything, so only `record` is worth a token.
    @Test(
        "a link that asks for nothing dangerous needs no token",
        arguments: [QuickCaptureLink.open, .paywall]
    )
    func harmlessLinksRouteWithoutAToken(link: QuickCaptureLink) {
        #expect(QuickCaptureLink.route(link.url, acceptedTokens: []) == link)
    }

    @Test("a record link the app built reads back as a record link")
    func recordRoundTrips() {
        let url = QuickCaptureLink.recordURL(token: token)

        #expect(url.absoluteString == "tidynote://record?t=\(token)")
        #expect(QuickCaptureLink.route(url, acceptedTokens: [token]) == .record)
    }

    /// The token the last rotation retired is still good, so a widget the
    /// system hasn't redrawn yet keeps working.
    @Test("either accepted token opens the microphone")
    func eitherAcceptedTokenRoutes() {
        let url = QuickCaptureLink.recordURL(token: token)

        #expect(QuickCaptureLink.route(url, acceptedTokens: ["other", token]) == .record)
    }

    /// What another app on the phone can build. It gets the app on screen and
    /// nothing else.
    @Test(
        "a record link without the right token only opens the app",
        arguments: [
            "tidynote://record",
            "tidynote://record?t=",
            "tidynote://record?t=guessed",
            "tidynote://record?token=3B1F0F0C-3D1B-4E6A-9E3E-6A2B0D5C1A77"
        ]
    )
    func recordWithoutTheTokenOnlyOpens(string: String) throws {
        let url = try #require(URL(string: string))

        #expect(QuickCaptureLink.route(url, acceptedTokens: [token]) == .open)
    }

    /// Before the first launch rotates one there is no token to match, so a
    /// record link can't be honoured however it was built.
    @Test("with no token stored, no record link is honoured")
    func noStoredTokenHonoursNothing() {
        let url = QuickCaptureLink.recordURL(token: token)

        #expect(QuickCaptureLink.route(url, acceptedTokens: []) == .open)
    }

    @Test("the scheme is matched however it is typed")
    func schemeIsCaseInsensitive() throws {
        let url = try #require(URL(string: "TidyNote://Record?t=\(token)"))

        #expect(QuickCaptureLink.route(url, acceptedTokens: [token]) == .record)
    }

    /// What a hand-typed link looks like: the target lands in the path rather
    /// than the host, and means the same thing.
    @Test("a target in the path routes like a target in the host")
    func targetInPathRoutes() throws {
        let url = try #require(URL(string: "tidynote:///paywall"))

        #expect(QuickCaptureLink.route(url, acceptedTokens: []) == .paywall)
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

        #expect(QuickCaptureLink.route(url, acceptedTokens: []) == nil)
    }
}
