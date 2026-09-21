# Phoros Core

The Rust half of Phoros 2 (BEAM-49): a sans-IO realtime state machine behind a C ABI, built as an XCFramework and wrapped by the `PhorosCore` target of the main package. Each release publishes `PhorosCore.xcframework.zip` as a GitHub release asset and `Package.swift` pins its checksum, so consumers never build Rust. Work on the core itself builds it here and links the local copy with `PHOROS_CORE_LOCAL=1`.

```
Core/
├── phoros-core/       # the Rust crate (cargo test works on its own)
├── include/           # phoros_core.h and the module map, the whole ABI
├── build.sh           # cargo for four Apple targets, lipo, xcodebuild -create-xcframework
└── build/             # the XCFramework, its zip and checksum (not committed)
```

```
Core/build.sh                          # needs rustup targets aarch64-apple-darwin, x86_64-apple-darwin, aarch64-apple-ios, aarch64-apple-ios-sim
PHOROS_CORE_LOCAL=1 swift test         # against the local build; without the variable, the released zip
```

Release: run `Core/build.sh`, put the printed checksum and the version in `Package.swift`, tag, then attach `Core/build/PhorosCore.xcframework.zip` to the GitHub release of that tag.

## The contract at the boundary

- The core owns no socket, clock or thread. Swift feeds it bytes with the time, polls it for what to do next (transmit these bytes, or call again by this time), and runs callbacks on the calling thread.
- Every entry point takes a handle and returns a status. A Rust panic is caught at the boundary and returned as `PHOROS_ERR_PANIC`; the handle is then poisoned and every later call returns `PHOROS_ERR_POISONED`. Nothing unwinds into Swift.
- Buffers fed in are copied by the core if it keeps them; the caller's buffer is never retained. A buffer handed out by `poll` belongs to the core and is valid until the next call on that handle.
- Callbacks run with the core's lock released, so a callback may call back into the core.
- Datagrams above 65535 bytes are refused, not truncated. Zero-length is a valid call.
- Threading misuse (two threads driving one handle) serializes on the core's lock; it cannot corrupt state.

## Measured

Boundary tests: 10,000 create/destroy cycles leave no handle alive; teardown fires its callback once; calls after destroy throw; a panic is contained and poisons; eight threads feeding 8,000 datagrams count correctly; a callback can re-enter. Cost of the boundary for a 1400-byte datagram through `feed` plus `poll`, including the one `Data` copy to a contiguous buffer: 141 ns on an M4 (about 10 GB/s), so the FFI is not where latency goes.

## The peer (BEAM-53)

`RealtimePeer` is a str0m session behind the same ABI: ICE (lite on the host), DTLS through `str0m-apple-crypto` (CommonCrypto and Security, no C crypto build for iOS), SCTP, and two pre-negotiated data channels, `reliable` (ordered) and `realtime` (unordered, 50 ms lifetime). The bootstrap carries one string each way (`ufrag`, `pass`, DTLS fingerprint) plus the address; `setRemote` starts everything. Two peers connect on loopback in the tests and exchange on both channels.

Two socket ownership designs are implemented and measured with a realtime-channel echo, 500 timestamped 64-byte messages at 2 ms, on loopback, M4:

| design | who owns UDP | p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| B | Rust, its own thread (`runOwnSocket`) | 449 µs | 660 | 856 | 1104 |
| A | Network.framework, `NetworkDrivenPeer` feeds the core on a dispatch queue | 513 µs | 733 | 1084 | 2145 |
| A + `.interactiveVideo` | same | 516 µs | 762 | 1150 | 2655 |

Design B is 60 µs faster at p50 and 230 µs at p99, the price of a dispatch hop and `Data` copies; both are far under a frame. The service class changes nothing on loopback, as expected (it is a Wi-Fi QoS marking). Two rules came out of getting these numbers: callbacks must run with the core's lock released, or an echo from a callback deadlocks; and a send from another thread must wake the driver (design B pokes its own socket with one byte, design A pumps on its queue), or the transmit waits for the next timeout.

str0m 0.23 is linked and its builder runs on every target, so the real state machine has a proven place to go. Static library size is large (four targets, 133 MB on disk) because `panic = "unwind"` and no symbol stripping are needed for containment and debugging; the app links only what it uses.
