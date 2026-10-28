#!/usr/bin/env bash
# Builds an x86_64 (Intel) UVScope.app, ad-hoc signed, and packs it into a DMG.
# Usage: scripts/build-intel.sh
# Output: build/UVScope-mac-x86_64.dmg
set -euo pipefail

cd "$(dirname "$0")/.."

NDI_SDK="/Library/NDI SDK for Apple"
DERIVED="build/DerivedData"
APP="$DERIVED/Build/Products/Release/UVScope.app"
STAGE="build/dmg-stage"
DMG="build/UVScope-mac-x86_64.dmg"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "error: this script must be run on macOS" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null; then
  echo "error: xcodebuild not found, install Xcode and run: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

if [[ ! -f "$NDI_SDK/include/Processing.NDI.Lib.h" ]]; then
  echo "error: NDI SDK for Apple not found in '$NDI_SDK'" >&2
  echo "       install it from https://ndi.video/for-developers/ndi-sdk/download/" >&2
  exit 1
fi

# Xcode 26 ships the Metal compiler as a separate component.
if ! xcrun metal --version >/dev/null 2>&1; then
  echo "Metal Toolchain is missing, downloading..."
  xcodebuild -downloadComponent MetalToolchain
fi

rm -rf "$DERIVED" "$STAGE" "$DMG"

# Ad-hoc signing without hardened runtime: library validation would otherwise
# refuse to load libndi.dylib, which is not signed with our (non-existent) team.
xcodebuild \
  -project UVScope.xcodeproj \
  -scheme NDIPlayground \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  ARCHS=x86_64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=NO \
  build

echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/UVScope")"
codesign --verify --deep --strict "$APP"

mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname UVScope -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "Done: $DMG"
