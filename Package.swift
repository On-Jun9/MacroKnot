// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacroKnot",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "MacroKnotCore", targets: ["MacroKnotCore"]),
        .executable(name: "MacroKnotApp", targets: ["MacroKnotApp"]),
    ],
    targets: [
        .target(
            name: "MacroKnotCore",
            path: "Sources/MacroKnotCore"
        ),
        .executableTarget(
            name: "MacroKnotApp",
            dependencies: ["MacroKnotCore"],
            path: "Sources/MacroKnotApp"
        ),
        .testTarget(
            name: "MacroKnotCoreTests",
            dependencies: ["MacroKnotCore"],
            path: "Tests/MacroKnotCoreTests"
        ),
        .testTarget(
            name: "MacroKnotAppTests",
            dependencies: ["MacroKnotApp", "MacroKnotCore"],
            path: "Tests/MacroKnotAppTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
