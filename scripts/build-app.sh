#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Default deliverable contains native Apple silicon and Intel slices.
swift build -c release --arch arm64 --arch x86_64
BINARY_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
APP_PATH="$PWD/dist/Mac验机助手.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY_DIR/MacDetect" "$APP_PATH/Contents/MacOS/MacDetect"
/usr/bin/swift scripts/make-icon.swift .build/MacDetect.iconset
/usr/bin/iconutil -c icns .build/MacDetect.iconset -o "$APP_PATH/Contents/Resources/AppIcon.icns"
cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleLocalizations</key><array><string>zh_CN</string><string>en</string></array>
<key>CFBundleExecutable</key><string>MacDetect</string>
<key>CFBundleIdentifier</key><string>local.macdetect.inspector</string>
<key>CFBundleName</key><string>Mac验机助手</string>
<key>CFBundleDisplayName</key><string>Mac验机助手</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
<key>NSHumanReadableCopyright</key><string>Mac Detect</string>
</dict></plist>
PLIST
if [ -n "${MACDETECT_SIGN_IDENTITY:-}" ]; then
    /usr/bin/codesign --force --options runtime --timestamp --sign "$MACDETECT_SIGN_IDENTITY" "$APP_PATH"
else
    /usr/bin/codesign --force --sign - --timestamp=none "$APP_PATH"
fi
/usr/bin/codesign --verify --strict "$APP_PATH"
if [ -n "${MACDETECT_NOTARY_PROFILE:-}" ]; then
    if [ -z "${MACDETECT_SIGN_IDENTITY:-}" ]; then
        echo 'Notarization requires MACDETECT_SIGN_IDENTITY.' >&2
        exit 1
    fi
    /usr/bin/ditto -c -k --keepParent "$APP_PATH" dist/notarize.zip
    xcrun notarytool submit dist/notarize.zip --keychain-profile "$MACDETECT_NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
fi
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" dist/MacDetect-0.1.0-universal.zip
/usr/bin/shasum -a 256 dist/MacDetect-0.1.0-universal.zip > dist/SHA256SUMS.txt
/usr/bin/lipo -info "$APP_PATH/Contents/MacOS/MacDetect"
echo "Built: $APP_PATH"
