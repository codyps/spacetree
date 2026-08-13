// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SpaceTree",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpaceTree", targets: ["SpaceTree"])
    ],
    targets: [
        .executableTarget(
            name: "SpaceTree",
            dependencies: ["SpaceTreeNative"],
            path: "Sources/SpaceTree"
        ),
        .target(
            name: "SpaceTreeNative",
            path: "Sources/SpaceTreeNative",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "SpaceTreeTests",
            dependencies: ["SpaceTree"],
            path: "Tests/SpaceTreeTests"
        )
    ]
)
