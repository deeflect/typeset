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
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.2.0")
    ],
    targets: [
        .target(
            name: "MarcoRendering",
            dependencies: [
                "MarcoCore",
                "Highlightr"
            ]
        )
    ]
)
