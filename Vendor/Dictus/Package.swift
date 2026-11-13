// swift-tools-version: 5.9
import PackageDescription

// Dictus v2.0.0 (MIT), vendored. Swift 5 language mode on purpose: the upstream
// code is written for it, and the Swift 6 app imports it without issue.
let package = Package(
    name: "Dictus",
    platforms: [.iOS(.v17)],
    products: [.library(name: "DictusModels", targets: ["DictusModels"])],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.18.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.8"),
    ],
    targets: [
        .target(name: "DictusCore", path: "Sources/DictusCore"),
        .target(
            name: "DictusModels",
            dependencies: [
                "DictusCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/DictusModels"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
