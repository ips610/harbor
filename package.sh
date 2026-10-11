#!/bin/bash
# Makes the two zips for the Releases page:
#   dist/harbor-apple-silicon.zip   M1 and newer
#   dist/harbor-intel.zip           Intel Macs
# One build per chip, like headroom: a universal app made macOS warn that it "will not open in
# macOS 28" once its Intel half ran under Rosetta. Nothing here runs Intel code, so build on an
# Apple Silicon Mac: the Intel copy is the Apple Silicon app with its program swapped.
set -euo pipefail
cd "$(dirname "$0")"
source ./app.conf
[ "$(uname -m)" = arm64 ] || { echo "error: build the release on an Apple Silicon Mac" >&2; exit 1; }

./build.sh
APP="build/$APP_NAME.app"
SIGN_ID="${SIGN_ID:-IPS Local Apps}"
sign() { codesign --force --sign "$SIGN_ID" "$1" 2>/dev/null || codesign --force --sign - "$1"; }

# Same toolchain as build.sh: Xcode's own, since the /usr/bin shims can stall.
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
  export SDKROOT="${SDKROOT:-$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
  SWIFT_BUILD=("$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-build")
else
  SWIFT_BUILD=(swift build)
fi
echo "==> swift build -c release --arch x86_64"
"${SWIFT_BUILD[@]}" -c release --arch x86_64
INTEL_BIN="$("${SWIFT_BUILD[@]}" -c release --arch x86_64 --show-bin-path)/$EXECUTABLE"
[ "$(lipo -archs "$INTEL_BIN")" = x86_64 ] || { echo "error: $INTEL_BIN isn't an Intel program" >&2; exit 1; }

rm -rf build/intel dist && mkdir -p build/intel dist
ditto "$APP" "build/intel/$APP_NAME.app"
cp "$INTEL_BIN" "build/intel/$APP_NAME.app/Contents/MacOS/$EXECUTABLE"
sign "build/intel/$APP_NAME.app"

ditto -c -k --keepParent "$APP" "dist/$APP_NAME-apple-silicon.zip"
ditto -c -k --keepParent "build/intel/$APP_NAME.app" "dist/$APP_NAME-intel.zip"
for z in dist/*.zip; do echo "Made: $z ($(du -h "$z" | cut -f1))"; done
