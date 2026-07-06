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
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.6.0")
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
        )
    ]
)
