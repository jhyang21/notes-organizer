import Foundation

/// Assembles a `multipart/form-data` body by hand.
///
/// `URLSession` uploads whatever bytes it is given but builds no multipart
/// body of its own, and the one part that matters here — a recording, as raw
/// bytes — can't be spelled in JSON without base64 inflating it by a third.
/// So this type does the framing: boundaries, part headers, the blank line
/// that ends them, and the closing delimiter, in the shape RFC 7578 asks for.
///
/// It knows nothing about audio, HTTP, or TidyNote. Fields and files go in,
/// `Data` comes out, and that is what lets the tests check it byte for byte.
struct MultipartFormBody {
    /// The delimiter that separates parts. Random by default, so it can't
    /// appear inside a recording by accident; injectable so a test can assert
    /// against a body it can predict.
    let boundary: String

    /// What the request's `Content-Type` has to say. Without the boundary in
    /// the header the receiver has no way to find where the parts start.
    var contentTypeHeader: String { "multipart/form-data; boundary=\(boundary)" }

    private var parts = Data()

    init(boundary: String = MultipartFormBody.randomBoundary()) {
        self.boundary = boundary
    }

    /// A plain text field, sent with no `Content-Type` of its own — the
    /// default of `text/plain` is already right, and saying so costs bytes.
    ///
    /// Names are literals at every call site, so there is nothing here that
    /// escapes a quote out of a name; keep it that way.
    mutating func appendField(name: String, value: String) {
        appendHeaders(disposition: #"form-data; name="\#(name)""#, contentType: nil)
        parts.append(Data(value.utf8))
        parts.append(Self.crlf)
    }

    /// A file part. `filename` and `contentType` are what the server sees, not
    /// anything read off disk, so the caller decides what the upload is called.
    mutating func appendFile(name: String, filename: String, contentType: String, data: Data) {
        appendHeaders(
            disposition: #"form-data; name="\#(name)"; filename="\#(filename)""#,
            contentType: contentType
        )
        parts.append(data)
        parts.append(Self.crlf)
    }

    /// Everything appended so far, closed off. Non-mutating on purpose: a
    /// caller can encode, look at the bytes, and still append more.
    func encoded() -> Data {
        var body = parts
        body.append(Data("--\(boundary)--".utf8))
        body.append(Self.crlf)
        return body
    }

    private mutating func appendHeaders(disposition: String, contentType: String?) {
        parts.append(Data("--\(boundary)".utf8))
        parts.append(Self.crlf)
        parts.append(Data("Content-Disposition: \(disposition)".utf8))
        parts.append(Self.crlf)
        if let contentType {
            parts.append(Data("Content-Type: \(contentType)".utf8))
            parts.append(Self.crlf)
        }
        // The blank line that ends a part's headers and begins its body.
        parts.append(Self.crlf)
    }

    private static let crlf = Data("\r\n".utf8)

    /// A UUID behind a fixed prefix: only characters a boundary is allowed to
    /// hold, and long enough that no recording will contain it by accident.
    static func randomBoundary() -> String {
        "tidynote.\(UUID().uuidString)"
    }
}
