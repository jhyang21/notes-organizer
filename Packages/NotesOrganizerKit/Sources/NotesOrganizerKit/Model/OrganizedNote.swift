import Foundation

/// A transcript reorganized into a clean, structured note. This is the
/// domain model the rest of the app works with — the app and share
/// extension never see the guided-generation types directly.
public struct OrganizedNote: Equatable, Sendable {
    public var title: String
    public var sections: [NoteSection]
    public var actionItems: [String]

    public init(title: String = "", sections: [NoteSection] = [], actionItems: [String] = []) {
        self.title = title
        self.sections = sections
        self.actionItems = actionItems
    }
}

/// One heading with its bullets. `heading` may be empty when the source
/// content is a single short thought that doesn't warrant a label.
public struct NoteSection: Equatable, Sendable {
    public var heading: String
    public var bullets: [String]

    public init(heading: String, bullets: [String] = []) {
        self.heading = heading
        self.bullets = bullets
    }
}
