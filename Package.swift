// swift-tools-version: 5.9

import PackageDescription

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
        .library(name: "PhorosInput", targets: ["PhorosInput"])
    ],
    targets: [
        .target(name: "Phoros"),
        .target(name: "PhorosSession", dependencies: ["Phoros"]),
        .target(name: "PhorosNetwork", dependencies: ["Phoros", "PhorosSession"]),
        .target(name: "PhorosMedia", dependencies: ["Phoros"]),
        .target(name: "PhorosInput", dependencies: ["Phoros"]),
        .testTarget(name: "PhorosTests", dependencies: ["Phoros"]),
        .testTarget(name: "PhorosSessionTests", dependencies: ["PhorosSession"]),
        .testTarget(name: "PhorosNetworkTests", dependencies: ["PhorosNetwork"]),
        .testTarget(name: "PhorosMediaTests", dependencies: ["PhorosMedia"]),
        .testTarget(name: "PhorosInputTests", dependencies: ["PhorosInput"])
    ]
)
