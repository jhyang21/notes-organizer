import Foundation

/// A transcript reorganized into a clean, structured note. This is the
/// domain model the rest of the app works with — the app and share
/// extension never see the guided-generation types directly.
///
/// `Codable` because it is also the cloud wire format: the organize endpoint
/// returns exactly this shape, so there is no DTO layer to keep in step with
/// it. Decoding is lenient about missing keys (an absent `actionItems` means
/// none, not a failed tidy) but strict about types.
public struct OrganizedNote: Codable, Equatable, Sendable {
    public var title: String
    public var sections: [NoteSection]
    public var actionItems: [String]

    public init(title: String = "", sections: [NoteSection] = [], actionItems: [String] = []) {
        self.title = title
        self.sections = sections
        self.actionItems = actionItems
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.sections = try container.decodeIfPresent([NoteSection].self, forKey: .sections) ?? []
        self.actionItems = try container.decodeIfPresent([String].self, forKey: .actionItems) ?? []
    }
}

/// One heading with its bullets. `heading` may be empty when the source
/// content is a single short thought that doesn't warrant a label.
public struct NoteSection: Codable, Equatable, Sendable {
    public var heading: String
    public var bullets: [String]

    public init(heading: String, bullets: [String] = []) {
        self.heading = heading
        self.bullets = bullets
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.heading = try container.decodeIfPresent(String.self, forKey: .heading) ?? ""
        self.bullets = try container.decodeIfPresent([String].self, forKey: .bullets) ?? []
    }
}
