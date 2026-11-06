// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MarcoRendering",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "MarcoRendering", targets: ["MarcoRendering"])
    ],
    dependencies: [
        .package(path: "../MarcoCore"),
        .package(url: "https://github.com/apple/swift-markdown.git", exact: "0.8.0"),
        .package(url: "https://github.com/raspu/Highlightr.git", exact: "2.3.0")
    ],
    targets: [
        .target(
            name: "MarcoRendering",
            dependencies: [
                "MarcoCore",
                .product(name: "Markdown", package: "swift-markdown"),
                "Highlightr"
            ]
        ),
        .testTarget(name: "MarcoRenderingTests", dependencies: ["MarcoRendering", "MarcoCore"])
    ]
)
