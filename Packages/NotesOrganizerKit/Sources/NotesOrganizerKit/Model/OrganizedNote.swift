import Foundation

/// A transcript reorganized into a clean, structured note. This is the
/// domain model the rest of the app works with — the app and share
/// extension never see the guided-generation types directly.
///
/// `Codable` because it is also the cloud wire format: the organize endpoint
/// returns exactly this shape, so there is no DTO layer to keep in step with
/// it. Decoding is lenient about missing keys (an absent `summary` means the
/// server had nothing to say, not a failed tidy) but strict about types.
///
/// There is no separate action-items list. A task list is a section whose
/// `kind` is `.checklist`, which keeps every block of a note the same shape
/// and lets the server put the tasks where they belong in the reading order.
public struct OrganizedNote: Codable, Equatable, Sendable {
    public var title: String
    /// A sentence or two of orientation above the sections. Often empty —
    /// the app organizes, it doesn't summarize — so it is shown only when
    /// the server sends one.
    public var summary: String
    public var sections: [NoteSection]

    public init(title: String = "", summary: String = "", sections: [NoteSection] = []) {
        self.title = title
        self.summary = summary
        self.sections = sections
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        self.sections = try container.decodeIfPresent([NoteSection].self, forKey: .sections) ?? []
    }
}

/// What a section's items are, and so how they read: prose, a list, a set of
/// checkboxes, an ordered procedure, or text to be reproduced exactly.
///
/// `verbatim` is the escape hatch for content that loses its meaning when it
/// is reflowed — a Wi-Fi password, an address, a snippet of code.
public enum SectionKind: String, Codable, Equatable, Sendable, CaseIterable {
    case paragraph
    case bullets
    case checklist
    case numbered
    case verbatim
}

/// One line of a section. `done` means something only in a `.checklist`
/// section; everywhere else it is false.
///
/// Decodes from either an object or a bare string, so a server that sends a
/// plain list of lines still produces items rather than a failed tidy. The
/// string-literal conformance is the same convenience for fixtures and
/// previews.
public struct NoteItem: Codable, Equatable, Sendable, ExpressibleByStringLiteral {
    public var text: String
    public var done: Bool

    public init(text: String, done: Bool = false) {
        self.text = text
        self.done = done
    }

    public init(stringLiteral value: String) {
        self.init(text: value)
    }

    public init(from decoder: any Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self.text = text
            self.done = false
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.done = try container.decodeIfPresent(Bool.self, forKey: .done) ?? false
    }
}

/// One heading with its items. `heading` may be empty when the source
/// content is a single short thought that doesn't warrant a label.
public struct NoteSection: Codable, Equatable, Sendable {
    public var heading: String
    public var kind: SectionKind
    public var items: [NoteItem]

    public init(heading: String, kind: SectionKind = .bullets, items: [NoteItem] = []) {
        self.heading = heading
        self.kind = kind
        self.items = items
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.heading = try container.decodeIfPresent(String.self, forKey: .heading) ?? ""
        // A kind this build doesn't know reads as bullets rather than as a
        // failure: the words are what matter, and a list is the shape that
        // loses the least when the label is wrong.
        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind)
        self.kind = rawKind.flatMap(SectionKind.init(rawValue:)) ?? .bullets
        self.items = try container.decodeIfPresent([NoteItem].self, forKey: .items) ?? []
    }
}
