#!/bin/bash
# Builds the Rust core for every Apple target and packages PhorosCore.xcframework.
# Consumers of the Swift package never run this: the XCFramework is what ships.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CRATE="$HERE/phoros-core"
OUT="$HERE/build"
rm -rf "$OUT"; mkdir -p "$OUT/macos" "$OUT/ios" "$OUT/sim"
cd "$CRATE"
for t in aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim; do
  cargo build --release --target "$t" 2>&1 | grep -E 'error|Finished' | tail -1
done
lipo -create "target/aarch64-apple-darwin/release/libphoros_core.a" "target/x86_64-apple-darwin/release/libphoros_core.a" -output "$OUT/macos/libphoros_core.a"
cp "target/aarch64-apple-ios/release/libphoros_core.a" "$OUT/ios/libphoros_core.a"
cp "target/aarch64-apple-ios-sim/release/libphoros_core.a" "$OUT/sim/libphoros_core.a"
xcodebuild -create-xcframework \
  -library "$OUT/macos/libphoros_core.a" -headers "$HERE/include" \
  -library "$OUT/ios/libphoros_core.a" -headers "$HERE/include" \
  -library "$OUT/sim/libphoros_core.a" -headers "$HERE/include" \
  -output "$OUT/PhorosCore.xcframework" | tail -1
du -sh "$OUT/PhorosCore.xcframework"
