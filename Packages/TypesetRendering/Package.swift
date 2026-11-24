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
        .package(url: "https://github.com/raspu/Highlightr.git", exact: "2.3.0"),
        .package(url: "https://github.com/Australware/swift-mermaid.git", exact: "0.3.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", exact: "1.7.3")
    ],
    targets: [
        .target(
            name: "TypesetRendering",
            dependencies: [
                "TypesetCore",
                .product(name: "Markdown", package: "swift-markdown"),
                "Highlightr",
                .product(name: "Mermaid", package: "swift-mermaid"),
                "SwiftMath"
            ]
        ),
        .testTarget(name: "TypesetRenderingTests", dependencies: ["TypesetRendering", "TypesetCore"])
    ]
)
