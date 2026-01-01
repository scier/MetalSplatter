// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MetalSplatter",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "PLYIO",
            targets: [ "PLYIO" ]
        ),
        .library(
            name: "SPZIO",
            targets: [ "SPZIO" ]
        ),
        .library(
            name: "SplatIO",
            targets: [ "SplatIO" ]
        ),
        .library(
            name: "MetalSplatter",
            targets: [ "MetalSplatter" ]
        ),
        .library(
            name: "SampleBoxRenderer",
            targets: [ "SampleBoxRenderer" ]
        ),
        .executable(
            name: "SplatConverter",
            targets: [ "SplatConverter" ]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "PLYIO",
            path: "PLYIO",
            sources: [ "Sources" ]
        ),
        .testTarget(
            name: "PLYIOTests",
            dependencies: [ "PLYIO" ],
            path: "PLYIO",
            sources: [ "Tests" ],
            resources: [ .copy("TestData") ]
        ),
        .target(
            name: "SPZIO",
            path: "SPZIO",
            sources: [ "Sources" ],
            publicHeadersPath: "Sources/include",
            cxxSettings: [
                .headerSearchPath("Sources/cpp"),
                .unsafeFlags(["-std=c++17"]),
            ],
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),
        .target(
            name: "SplatIO",
            dependencies: [ "PLYIO", "SPZIO" ],
            path: "SplatIO",
            sources: [ "Sources" ]
        ),
        .testTarget(
            name: "SplatIOTests",
            dependencies: [ "SplatIO" ],
            path: "SplatIO",
            sources: [ "Tests" ],
            resources: [ .copy("TestData") ]
        ),
        .target(
            name: "MetalSplatter",
            dependencies: [ "PLYIO", "SplatIO" ],
            path: "MetalSplatter",
            sources: [ "Sources" ],
            resources: [ .process("Resources") ]
        ),
        .target(
            name: "SampleBoxRenderer",
            path: "SampleBoxRenderer",
            sources: [ "Sources" ],
            resources: [ .process("Resources") ]
        ),
        .executableTarget(
            name: "SplatConverter",
            dependencies: [
                "SplatIO",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "SplatConverter",
            sources: [ "Sources" ]
        ),
    ]
)
