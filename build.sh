#!/bin/zsh
# Builds a standalone XcodeSwitcher.app into ./build (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/XcodeSwitcher.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary (Apple Silicon + Intel) so the DMG works on any Mac.
OBJ=build/obj
mkdir -p "$OBJ"
for ARCH in arm64 x86_64; do
  swiftc -O -parse-as-library \
    -target "$ARCH-apple-macos13.0" \
    Sources/*.swift \
    -o "$OBJ/XcodeSwitcher-$ARCH"
done
lipo -create "$OBJ"/XcodeSwitcher-arm64 "$OBJ"/XcodeSwitcher-x86_64 \
  -output "$APP/Contents/MacOS/XcodeSwitcher"

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>XcodeSwitcher</string>
  <key>CFBundleDisplayName</key><string>Xcode Switcher</string>
  <key>CFBundleIdentifier</key><string>com.newsid.xcodeswitcher</string>
  <key>CFBundleExecutable</key><string>XcodeSwitcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

# Shareable disk image: the app plus an /Applications shortcut for drag-to-install.
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="build/XcodeSwitcher-$VERSION.dmg"
STAGE=build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
if diskutil image create from --help >/dev/null 2>&1; then
  # macOS 27+: hdiutil create is deprecated.
  diskutil image create from --format UDZO --volumeName "Xcode Switcher" "$STAGE" "$DMG" >/dev/null
else
  hdiutil create -volname "Xcode Switcher" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
fi
rm -rf "$STAGE" "$OBJ"
echo "Built $DMG"
