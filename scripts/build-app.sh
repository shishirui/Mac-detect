#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_VERSION="$(sed -n 's/^public let appVersion = "\([0-9.]*\)"$/\1/p' Sources/MacDetectCore/Models.swift)"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo 'Cannot determine application version.' >&2
    exit 1
fi
OUTPUT_DIR="${MACDETECT_OUTPUT_DIR:-$PWD/dist}"
mkdir -p "$OUTPUT_DIR" .build/notarization
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
APP_PATH="$OUTPUT_DIR/Mac验机助手.app"
ZIP_NAME="MacDetect-$APP_VERSION-universal.zip"

NOTARY_ARGS=()
WANTS_NOTARIZATION=0
if [ -n "${MACDETECT_NOTARY_PROFILE:-}" ]; then
    NOTARY_ARGS=(--keychain-profile "$MACDETECT_NOTARY_PROFILE")
    WANTS_NOTARIZATION=1
elif [ -n "${MACDETECT_NOTARY_KEY_PATH:-}${MACDETECT_NOTARY_KEY_ID:-}${MACDETECT_NOTARY_ISSUER_ID:-}" ]; then
    if [ -z "${MACDETECT_NOTARY_KEY_PATH:-}" ] || [ -z "${MACDETECT_NOTARY_KEY_ID:-}" ]; then
        echo 'API notarization requires both a key path and a key ID.' >&2
        exit 1
    fi
    NOTARY_ARGS=(--key "$MACDETECT_NOTARY_KEY_PATH" --key-id "$MACDETECT_NOTARY_KEY_ID")
    if [ -n "${MACDETECT_NOTARY_ISSUER_ID:-}" ]; then
        NOTARY_ARGS+=(--issuer "$MACDETECT_NOTARY_ISSUER_ID")
    fi
    WANTS_NOTARIZATION=1
fi
if [ "$WANTS_NOTARIZATION" = 1 ] && [ -z "${MACDETECT_SIGN_IDENTITY:-}" ]; then
    echo 'Notarization requires MACDETECT_SIGN_IDENTITY.' >&2
    exit 1
fi
if [ "${MACDETECT_REQUIRE_NOTARIZATION:-0}" = 1 ] && { [ -z "${MACDETECT_SIGN_IDENTITY:-}" ] || [ "$WANTS_NOTARIZATION" != 1 ]; }; then
    echo 'Release builds require both a Developer ID identity and notarization credentials.' >&2
    exit 1
fi

# Default deliverable contains native Apple silicon and Intel slices.
swift build -c release --arch arm64 --arch x86_64
BINARY_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY_DIR/MacDetect" "$APP_PATH/Contents/MacOS/MacDetect"
/usr/bin/swift scripts/make-icon.swift .build/MacDetect.iconset
/usr/bin/iconutil -c icns .build/MacDetect.iconset -o "$APP_PATH/Contents/Resources/AppIcon.icns"
cat > "$APP_PATH/Contents/Info.plist" <<PLIST
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
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>$APP_VERSION</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
<key>NSHumanReadableCopyright</key><string>Mac Detect</string>
</dict></plist>
PLIST

if [ -n "${MACDETECT_SIGN_IDENTITY:-}" ]; then
    /usr/bin/codesign --force --options runtime --timestamp --sign "$MACDETECT_SIGN_IDENTITY" "$APP_PATH"
    SIGNATURE_DETAILS="$(/usr/bin/codesign --display --verbose=4 "$APP_PATH" 2>&1)"
    if [[ "$SIGNATURE_DETAILS" != *"Authority=Developer ID Application:"* ]] || [[ "$SIGNATURE_DETAILS" != *"Timestamp="* ]]; then
        echo 'Distribution requires a Developer ID Application signature and secure timestamp.' >&2
        exit 1
    fi
else
    /usr/bin/codesign --force --sign - --timestamp=none "$APP_PATH"
fi
/usr/bin/codesign --verify --strict "$APP_PATH"

if [ "$WANTS_NOTARIZATION" = 1 ]; then
    SUBMISSION_ARCHIVE="$PWD/.build/notarization/MacDetect-$APP_VERSION-submit.zip"
    SUBMISSION_RESULT="$PWD/.build/notarization/MacDetect-$APP_VERSION-submission.json"
    /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$SUBMISSION_ARCHIVE"
    echo 'Submitting the signed app to Apple; waiting for notarization...'
    xcrun notarytool submit "$SUBMISSION_ARCHIVE" "${NOTARY_ARGS[@]}" --wait --timeout 15m --output-format json > "$SUBMISSION_RESULT"
    NOTARY_STATUS="$(/usr/bin/plutil -extract status raw -o - "$SUBMISSION_RESULT")"
    if [ "$NOTARY_STATUS" != Accepted ]; then
        echo "Notarization was not accepted; see $SUBMISSION_RESULT" >&2
        exit 1
    fi
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    /usr/bin/codesign --verify --strict "$APP_PATH"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$APP_PATH"
    echo 'Apple notarization accepted; ticket stapled and Gatekeeper assessment passed.'
else
    echo 'Local build only: this app has NOT been notarized.'
fi

# Package only after the accepted ticket has been stapled, for offline verification.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT_DIR/$ZIP_NAME"
(cd "$OUTPUT_DIR" && /usr/bin/shasum -a 256 "$ZIP_NAME" > SHA256SUMS.txt)
/usr/bin/lipo -info "$APP_PATH/Contents/MacOS/MacDetect"
echo "Built: $APP_PATH"
