import Foundation
import Testing
@testable import NotesOrganizerKit

@Suite("MultipartFormBody")
struct MultipartFormBodyTests {
    private let boundary = "tidynote.TEST-BOUNDARY"

    /// Multipart framing is bytes, not text, so the assertions compare bytes.
    /// Latin-1 is the one encoding where every byte 0…255 round-trips, which
    /// makes a body holding binary readable as a `String` without losing any
    /// of it.
    private func text(_ data: Data) throws -> String {
        try #require(String(data: data, encoding: .isoLatin1))
    }

    // MARK: - Framing

    @Test("an empty body is nothing but the closing delimiter")
    func encodesEmptyBody() throws {
        let body = MultipartFormBody(boundary: boundary)
        let encoded = try text(body.encoded())

        #expect(encoded == "--tidynote.TEST-BOUNDARY--\r\n")
    }

    @Test("a text field carries its name, a blank line, then its value")
    func encodesOneField() throws {
        var body = MultipartFormBody(boundary: boundary)
        body.appendField(name: "clientVersion", value: "1.2 (34)")

        let expected = "--tidynote.TEST-BOUNDARY\r\n"
            + "Content-Disposition: form-data; name=\"clientVersion\"\r\n"
            + "\r\n"
            + "1.2 (34)\r\n"
            + "--tidynote.TEST-BOUNDARY--\r\n"
        let encoded = try text(body.encoded())
        #expect(encoded == expected)
    }

    @Test("a file part adds a filename and a content type of its own")
    func encodesOneFile() throws {
        var body = MultipartFormBody(boundary: boundary)
        body.appendFile(name: "audio", filename: "capture.m4a", contentType: "audio/mp4", data: Data("abc".utf8))

        let expected = "--tidynote.TEST-BOUNDARY\r\n"
            + "Content-Disposition: form-data; name=\"audio\"; filename=\"capture.m4a\"\r\n"
            + "Content-Type: audio/mp4\r\n"
            + "\r\n"
            + "abc\r\n"
            + "--tidynote.TEST-BOUNDARY--\r\n"
        let encoded = try text(body.encoded())
        #expect(encoded == expected)
    }

    @Test("parts come out in the order they went in, each opened by the boundary")
    func keepsPartOrder() throws {
        var body = MultipartFormBody(boundary: boundary)
        body.appendFile(name: "audio", filename: "capture.m4a", contentType: "audio/mp4", data: Data([0x01]))
        body.appendField(name: "appUserId", value: "tidy:abc")
        body.appendField(name: "durationSeconds", value: "42")

        let encoded = try text(body.encoded())
        let audioAt = try #require(encoded.range(of: "name=\"audio\"")).lowerBound
        let userAt = try #require(encoded.range(of: "name=\"appUserId\"")).lowerBound
        let durationAt = try #require(encoded.range(of: "name=\"durationSeconds\"")).lowerBound
        #expect(audioAt < userAt)
        #expect(userAt < durationAt)

        // One opening delimiter per part, and exactly one closing one.
        #expect(encoded.components(separatedBy: "--tidynote.TEST-BOUNDARY\r\n").count == 4)
        #expect(encoded.hasSuffix("--tidynote.TEST-BOUNDARY--\r\n"))
    }

    // MARK: - Binary safety

    @Test("file bytes survive the middle of a body untouched")
    func keepsFileBytesIntact() throws {
        // The bytes a recording is made of: nulls, high bytes, and something
        // that looks like a line break but isn't a delimiter.
        let audio = Data([0x00, 0xFF, 0x0D, 0x0A, 0x2D, 0x2D, 0x7F, 0x80])
        var body = MultipartFormBody(boundary: boundary)
        body.appendField(name: "before", value: "x")
        body.appendFile(name: "audio", filename: "capture.m4a", contentType: "audio/mp4", data: audio)
        body.appendField(name: "after", value: "y")

        let encoded = body.encoded()
        let marker = Data("Content-Type: audio/mp4\r\n\r\n".utf8)
        let headerEnd = try #require(encoded.range(of: marker)).upperBound
        #expect(encoded[headerEnd..<(headerEnd + audio.count)] == audio)
        // And the part ends where it should, rather than swallowing the CRLF.
        #expect(encoded[(headerEnd + audio.count)...].starts(with: Data("\r\n--".utf8)))
    }

    @Test("a value the file couldn't hold as ASCII still goes out as UTF-8")
    func encodesValuesAsUTF8() throws {
        var body = MultipartFormBody(boundary: boundary)
        body.appendField(name: "locale", value: "ko-KR")
        body.appendField(name: "note", value: "안녕")

        #expect(body.encoded().range(of: Data("안녕".utf8)) != nil)
    }

    // MARK: - Header

    @Test("the content type header names the boundary the body was framed with")
    func headerMatchesBoundary() throws {
        let body = MultipartFormBody(boundary: boundary)

        #expect(body.contentTypeHeader == "multipart/form-data; boundary=tidynote.TEST-BOUNDARY")
    }

    @Test("a generated boundary is unique and legal")
    func generatesUsableBoundaries() {
        let first = MultipartFormBody.randomBoundary()
        let second = MultipartFormBody.randomBoundary()

        #expect(first != second)
        // A boundary may only hold characters an HTTP header can carry as-is.
        let legal = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        #expect(first.unicodeScalars.allSatisfy { legal.contains($0) })
        #expect(first.count <= 70)
    }

    @Test("encoding twice doesn't consume the parts")
    func encodingIsRepeatable() throws {
        var body = MultipartFormBody(boundary: boundary)
        body.appendField(name: "a", value: "1")

        #expect(body.encoded() == body.encoded())
    }
}
