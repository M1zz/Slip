// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SlipCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "SlipCore", targets: ["SlipCore"])
    ],
    dependencies: [
        // Apple's Markdown parser — produces a Markup tree with source ranges
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.4.0"),
        // GRDB — idiomatic Swift SQLite with first-class FTS5 support
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(
            name: "SlipCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/SlipCore"
        ),
        .testTarget(
            name: "SlipCoreTests",
            dependencies: ["SlipCore"],
            path: "Tests/SlipCoreTests"
        )
    ]
)
