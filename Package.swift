// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenPhoto",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "OpenPhotoCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Resources/AdaFaceIR101.mlpackage")],
            linkerSettings: [.linkedFramework("ImageCaptureCore")]
        ),
        .executableTarget(
            name: "OpenPhotoApp",
            dependencies: ["OpenPhotoCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .executableTarget(
            name: "ICCSpike",
            linkerSettings: [.linkedFramework("ImageCaptureCore")]
        ),
        // Dev-only: compares candidate image encoders on this Mac. See tools/embed-bench/.
        // Depends on Core purely to reuse CLIPTokenizer, so the MobileCLIP baseline can be scored
        // for quality too rather than only timed.
        .executableTarget(name: "EmbedBench", dependencies: ["OpenPhotoCore"]),
        .testTarget(
            name: "OpenPhotoCoreTests",
            dependencies: ["OpenPhotoCore"]
        ),
        // Pure, AppKit-free parts of the app target (grid layout maths, badge decisions, update diff).
        .testTarget(
            name: "OpenPhotoAppTests",
            dependencies: ["OpenPhotoApp", "OpenPhotoCore"]
        ),
    ]
)
