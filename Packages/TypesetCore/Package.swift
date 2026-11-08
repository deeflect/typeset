// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TypesetCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "TypesetCore", targets: ["TypesetCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", exact: "0.8.0"),
        .package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.8.0")
    ],
    targets: [
        .target(
            name: "TypesetCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ]
        ),
        .testTarget(
            name: "TypesetCoreTests",
            dependencies: ["TypesetCore"]
        ),
        // Perf harness: `swift run -c release TypesetCoreBenchmark` prints
        // Release-mode phase timings against the fixtures in
        // Tests/Fixtures/generated (see Scripts/make-fixtures.sh). Not
        // part of the library product — diagnostics only.
        .executableTarget(
            name: "TypesetCoreBenchmark",
            dependencies: ["TypesetCore"]
        )
    ]
)
