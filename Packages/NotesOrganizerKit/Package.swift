// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NotesOrganizerKit",
    platforms: [
        .iOS(.v26)
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
            dependencies: []
        ),
        .testTarget(
            name: "NotesOrganizerKitTests",
            dependencies: ["NotesOrganizerKit"]
        )
    ]
)
