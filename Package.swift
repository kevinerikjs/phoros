// swift-tools-version: 5.9

import Foundation
import PackageDescription

// PhorosCore: the Rust core behind a C ABI, shipped as an XCFramework on each release.
// PHOROS_CORE_LOCAL=1 (or an xcodeproj built with that in its environment) links the one
// Core/build.sh just produced instead, for work on the core itself.
let coreVersion = "1.4.2"
let coreChecksum = "b076df47b100555b753cb26e2623fcf185c302bede2995b6084aa17cf9b4b2a7"
let coreFFI: Target = ProcessInfo.processInfo.environment["PHOROS_CORE_LOCAL"] != nil
    ? .binaryTarget(name: "PhorosCoreFFI", path: "Core/build/PhorosCore.xcframework")
    : .binaryTarget(name: "PhorosCoreFFI",
                    url: "https://github.com/kevinerikjs/phoros/releases/download/\(coreVersion)/PhorosCore.xcframework.zip",
                    checksum: coreChecksum)

let package = Package(
    name: "Phoros",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .visionOS(.v1)
    ],
    products: [
        // The wire contract. Foundation only.
        .library(name: "Phoros", targets: ["Phoros"]),
        // Session logic on top of the contract: pairing and auth state machines, frame
        // reassembly, audio sequencing, send backlog policy, quality adaptation. No I/O.
        .library(name: "PhorosSession", targets: ["PhorosSession"]),
        // Length-prefixed transport over Network.framework.
        .library(name: "PhorosNetwork", targets: ["PhorosNetwork"]),
        // Codecs shaped for the wire: H.264/HEVC via VideoToolbox, AAC-LC via AudioToolbox,
        // parameter sets, Annex B, sample buffers.
        .library(name: "PhorosMedia", targets: ["PhorosMedia"]),
        // Game controller forwarding: sampling on the client, a virtual HID gamepad on
        // a macOS host, and the HID report mapping between them.
        .library(name: "PhorosInput", targets: ["PhorosInput"]),
        // Phoros 2: the realtime peer (UDP, RTP, str0m) from the Rust core, and the
        // transport built on it.
        .library(name: "PhorosCore", targets: ["PhorosCore"])
    ],
    targets: [
        .target(name: "Phoros"),
        .target(name: "PhorosSession", dependencies: ["Phoros"]),
        .target(name: "PhorosNetwork", dependencies: ["Phoros", "PhorosSession"]),
        .target(name: "PhorosMedia", dependencies: ["Phoros"]),
        .target(name: "PhorosInput", dependencies: ["Phoros"]),
        coreFFI,
        .target(name: "PhorosCore", dependencies: ["PhorosCoreFFI", "Phoros", "PhorosSession"]),
        .testTarget(name: "PhorosCoreTests", dependencies: ["PhorosCore"]),
        .testTarget(name: "PhorosTests", dependencies: ["Phoros"]),
        .testTarget(name: "PhorosSessionTests", dependencies: ["PhorosSession"]),
        .testTarget(name: "PhorosNetworkTests", dependencies: ["PhorosNetwork"]),
        .testTarget(name: "PhorosMediaTests", dependencies: ["PhorosMedia"]),
        .testTarget(name: "PhorosInputTests", dependencies: ["PhorosInput"])
    ]
)
