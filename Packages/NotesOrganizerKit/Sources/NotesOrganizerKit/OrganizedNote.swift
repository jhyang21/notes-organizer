import Foundation

/// Placeholder shape for an organized note.
///
/// M0 exists only to prove the app, share extension, and package all
/// compile and link together. This will become the `@Generable` guided
/// generation schema in M3 — see the plan's Architecture section for the
/// intended `title / sections[{heading, bullets}] / actionItems` shape.
public struct OrganizedNote: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}
