#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
WORKSPACE_DIR="$PROJECT_DIR"
OUTPUT_DIR="$WORKSPACE_DIR/outputs"
BUILD_DIR="$PROJECT_DIR/.build-release"
TEST_BUILD_DIR="$PROJECT_DIR/.build-package-test"
CLANG_CACHE_DIR="$PROJECT_DIR/.cache/package-clang"
SWIFTPM_CACHE_DIR="$PROJECT_DIR/.cache/package-swiftpm"
APP_BUNDLE="$OUTPUT_DIR/ChatGPT Profile Manager.app"
APP_ZIP="$OUTPUT_DIR/ChatGPT-Profile-Manager-macOS.zip"

if [[ -e "$APP_BUNDLE" || -e "$APP_ZIP" ]]; then
  print -u2 "Output already exists. Move the existing app and zip before packaging again."
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_DIR" \
SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE_DIR" \
swift test \
  --disable-sandbox \
  --package-path "$PROJECT_DIR" \
  --scratch-path "$TEST_BUILD_DIR"

CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_DIR" \
SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE_DIR" \
swift build \
  --disable-sandbox \
  --package-path "$PROJECT_DIR" \
  --configuration release \
  --build-path "$BUILD_DIR"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/release/ChatGPTProfileManager" \
  "$APP_BUNDLE/Contents/MacOS/ChatGPTProfileManager"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/PkgInfo" "$APP_BUNDLE/Contents/PkgInfo"
cp "$PROJECT_DIR/Resources/AppIcon.icns" \
  "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp -R "$PROJECT_DIR/Resources/en.lproj" \
  "$APP_BUNDLE/Contents/Resources/en.lproj"

codesign --force --deep --sign - "$APP_BUNDLE"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$APP_ZIP"

print "$APP_BUNDLE"
print "$APP_ZIP"
