// swift-tools-version: 5.9
// The Rust core as a Swift package: a binary target for the XCFramework and a thin Swift
// wrapper over its C ABI. Separate from the main Phoros package on purpose: a binary target
// whose file is missing breaks every consumer's resolution, and this one is built locally
// with ./build.sh until it ships as a release artifact.
import PackageDescription

let package = Package(
    name: "PhorosCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "PhorosCore", targets: ["PhorosCore"])],
    dependencies: [.package(path: "..")],
    targets: [
        .binaryTarget(name: "PhorosCoreFFI", path: "build/PhorosCore.xcframework"),
        .target(name: "PhorosCore", dependencies: [
            "PhorosCoreFFI",
            .product(name: "Phoros", package: "phoros"),
            .product(name: "PhorosSession", package: "phoros")
        ]),
        .testTarget(name: "PhorosCoreTests", dependencies: ["PhorosCore"])
    ]
)
