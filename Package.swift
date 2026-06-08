// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenPhoto",
    platforms: [.macOS(.v15)],
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
        .executableTarget(
            name: "ICCSpike",
            linkerSettings: [.linkedFramework("ImageCaptureCore")]
        ),
        .testTarget(
            name: "OpenPhotoCoreTests",
            dependencies: ["OpenPhotoCore"]
        ),
    ]
)
