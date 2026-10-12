#!/bin/bash
# Build the app (release, ad-hoc signed) into ./build/. Name and bundle id come from app.conf.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
source "$ROOT/app.conf"
APP="$ROOT/build/$APP_NAME.app"
VERSION="1.3.0"

# Call Xcode's toolchain directly when it exists: on some Macs the /usr/bin
# xcrun shims stall for minutes.
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
  export SDKROOT="${SDKROOT:-$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
  SWIFT_BUILD=("$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-build")
else
  SWIFT_BUILD=(swift build)
fi

echo "==> swift build -c release"
"${SWIFT_BUILD[@]}" -c release
BIN="$ROOT/.build/release/$EXECUTABLE"
[ -x "$BIN" ] || { echo "error: $BIN not found" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$ROOT"/build/*.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"

# Icon: the binary draws it from an SF Symbol; skipped if anything fails.
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
if "$BIN" --make-icon "$ICONSET" && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"; then
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  echo "warning: icon skipped"
  ICON_KEY=""
fi
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>$APP_NAME asks an app to quit when you click Quit.</string>
  $ICON_KEY
</dict>
</plist>
PLIST

# The same certificate every build keeps macOS's permissions for the app; ad-hoc changes with
# every build. SIGN_ID picks another one (a Developer ID later); no certificate → ad-hoc.
SIGN_ID="${SIGN_ID:-IPS Local Apps}"
echo "==> Signing ($SIGN_ID)"
codesign --force --sign "$SIGN_ID" "$APP" 2>/dev/null || { echo "    not found, signing ad-hoc"; codesign --force --sign - "$APP"; }
codesign --verify --strict "$APP"
echo "Built: $APP"
