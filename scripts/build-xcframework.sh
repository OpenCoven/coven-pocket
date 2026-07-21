#!/usr/bin/env bash
# Build the Rust engine for iOS and generate Swift bindings + XCFramework.
#
# Outputs:
#   build/CovenPocketCore.xcframework   (static lib + headers, device + sim)
#   app/Sources/Generated/*.swift       (UniFFI Swift bindings)
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${PROFILE:-release}"
CARGO_FLAG=""
[ "$PROFILE" = "release" ] && CARGO_FLAG="--release"

# Keep C deps (bundled sqlite3, ring, …) aligned with the app's minimum OS.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

LIB_NAME=libcoven_pocket_ffi
TARGET_DIR=rust/target
OUT=build
BINDINGS="$OUT/bindings"

echo "==> Building Rust core (device + simulator, $PROFILE)"
(cd rust && cargo build -p coven-pocket-ffi $CARGO_FLAG --target aarch64-apple-ios)
(cd rust && cargo build -p coven-pocket-ffi $CARGO_FLAG --target aarch64-apple-ios-sim)

echo "==> Building host cdylib for bindgen metadata"
(cd rust && cargo build -p coven-pocket-ffi $CARGO_FLAG)

echo "==> Generating Swift bindings"
rm -rf "$BINDINGS"
(cd rust && cargo run -p coven-pocket-bindgen $CARGO_FLAG --bin uniffi-bindgen -- \
    generate --library "target/$PROFILE/$LIB_NAME.dylib" \
    --language swift --out-dir "../$BINDINGS")

mkdir -p app/Sources/Generated
cp "$BINDINGS"/*.swift app/Sources/Generated/

echo "==> Assembling XCFramework"
HEADERS_IOS="$OUT/headers-ios"
HEADERS_SIM="$OUT/headers-sim"
for headers in "$HEADERS_IOS" "$HEADERS_SIM"; do
  rm -rf "$headers"
  mkdir -p "$headers"
  cp "$BINDINGS"/*.h "$headers/"
  cat "$BINDINGS"/*.modulemap > "$headers/module.modulemap"
done

rm -rf "$OUT/CovenPocketCore.xcframework"
xcodebuild -create-xcframework \
  -library "$TARGET_DIR/aarch64-apple-ios/$PROFILE/$LIB_NAME.a" -headers "$HEADERS_IOS" \
  -library "$TARGET_DIR/aarch64-apple-ios-sim/$PROFILE/$LIB_NAME.a" -headers "$HEADERS_SIM" \
  -output "$OUT/CovenPocketCore.xcframework"

echo "==> Done: $OUT/CovenPocketCore.xcframework"
