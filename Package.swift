// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SpaceTree",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpaceTree", targets: ["SpaceTree"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "SpaceTree",
            dependencies: ["SpaceTreeNative", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/SpaceTree",
            resources: [.process("Resources")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .target(
            name: "SpaceTreeNative",
            path: "Sources/SpaceTreeNative",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "SpaceTreeTests",
            dependencies: ["SpaceTree", "SpaceTreeNative"],
            path: "Tests/SpaceTreeTests"
        )
    ]
)
