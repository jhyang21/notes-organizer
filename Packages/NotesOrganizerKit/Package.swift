// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NotesOrganizerKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "NotesOrganizerKit",
            targets: ["NotesOrganizerKit"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "NotesOrganizerKit",
            dependencies: [],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "NotesOrganizerKitTests",
            dependencies: ["NotesOrganizerKit"]
        )
    ]
)
