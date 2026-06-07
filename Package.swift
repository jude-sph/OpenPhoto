// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenPhoto",
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "OpenPhotoCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "OpenPhotoApp",
            dependencies: ["OpenPhotoCore"]
        ),
        .executableTarget(name: "ICCSpike"),
        .testTarget(
            name: "OpenPhotoCoreTests",
            dependencies: ["OpenPhotoCore"]
        ),
    ]
)
