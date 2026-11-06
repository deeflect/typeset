// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MarcoCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "MarcoCore", targets: ["MarcoCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", exact: "0.8.0"),
        .package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.8.0")
    ],
    targets: [
        .target(
            name: "MarcoCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ]
        ),
        .testTarget(
            name: "MarcoCoreTests",
            dependencies: ["MarcoCore"]
        ),
        // Perf harness: `swift run -c release MarcoCoreBenchmark` prints
        // Release-mode phase timings against the fixtures in
        // Tests/Fixtures/generated (see Scripts/make-fixtures.sh). Not
        // part of the library product — diagnostics only.
        .executableTarget(
            name: "MarcoCoreBenchmark",
            dependencies: ["MarcoCore"]
        )
    ]
)
