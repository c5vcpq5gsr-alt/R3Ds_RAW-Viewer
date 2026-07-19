// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RAWViewer",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "RAWViewer", targets: ["RAWViewer"])
    ],
    targets: [
        .executableTarget(
            name: "RAWViewer",
            path: "Sources/RAWViewer"
        ),
        .testTarget(
            name: "RAWViewerTests",
            dependencies: ["RAWViewer"]
        )
    ]
)
