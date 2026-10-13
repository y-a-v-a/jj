// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JJ",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MyriaCore", targets: ["MyriaCore"]),
        .library(name: "MyriaData", targets: ["MyriaData"]),
        .library(name: "MyriaLayouts", targets: ["MyriaLayouts"]),
        .library(name: "MyriaRender", targets: ["MyriaRender"]),
        .executable(name: "JJApp", targets: ["JJApp"]),
        .executable(name: "jj", targets: ["JJCommand"]),
        .executable(name: "jj-data", targets: ["JJDataPrep"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Geometry: myriahedra, their dual graphs, spanning trees, unfolding and folding.
        .target(name: "MyriaCore"),
        // Celestial bodies and their data: vector layers, fields on the sphere.
        .target(
            name: "MyriaData",
            dependencies: ["MyriaCore"],
            resources: [.copy("Resources/Earth"), .copy("Resources/Moon"), .copy("Resources/Mars"), .copy("Resources/Venus")]
        ),
        // Layouts: where to cut the myriahedron.
        .target(name: "MyriaLayouts", dependencies: ["MyriaCore", "MyriaData"]),
        // Palettes, scene geometry and the Metal renderer.
        .target(name: "MyriaRender", dependencies: ["MyriaCore", "MyriaData", "MyriaLayouts"]),
        .executableTarget(name: "JJApp", dependencies: ["MyriaCore", "MyriaData", "MyriaLayouts", "MyriaRender"]),
        .executableTarget(
            name: "JJCommand",
            dependencies: ["MyriaCore", "MyriaData", "MyriaLayouts", "MyriaRender",
                           .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .executableTarget(
            name: "JJDataPrep",
            dependencies: ["MyriaCore", "MyriaData", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(name: "MyriaCoreTests", dependencies: ["MyriaCore"]),
        .testTarget(name: "MyriaDataTests", dependencies: ["MyriaData"]),
        .testTarget(name: "MyriaLayoutsTests", dependencies: ["MyriaLayouts"]),
        .testTarget(name: "MyriaRenderTests", dependencies: ["MyriaRender", "MyriaLayouts"], exclude: ["Snapshots", "Output"]),
    ]
)
