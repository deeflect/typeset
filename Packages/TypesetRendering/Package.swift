// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TypesetRendering",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "TypesetRendering", targets: ["TypesetRendering"])
    ],
    dependencies: [
        .package(path: "../TypesetCore"),
        .package(url: "https://github.com/apple/swift-markdown.git", exact: "0.8.0"),
        .package(url: "https://github.com/raspu/Highlightr.git", exact: "2.3.0")
    ],
    targets: [
        .target(
            name: "TypesetRendering",
            dependencies: [
                "TypesetCore",
                .product(name: "Markdown", package: "swift-markdown"),
                "Highlightr"
            ]
        ),
        .testTarget(name: "TypesetRenderingTests", dependencies: ["TypesetRendering", "TypesetCore"])
    ]
)
