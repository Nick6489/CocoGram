#!/usr/bin/env bash
#
# package.sh — build, bundle, sign, notarize, and staple CocoGram.app for direct
# (ad-hoc) distribution.
#
# Pipeline: swift build -c release -> assemble CocoGram.app -> Info.plist -> icon
#           -> codesign (Developer ID + hardened runtime) -> notarize -> staple -> verify.
#
# Secrets: the App Store Connect API key (.p8) is NEVER copied into the repo. Pass it by
# path via env vars (defaults point at ~/Downloads). Nothing secret is echoed.
#
# Required tools: swift, codesign, iconutil, ditto, xcrun notarytool, xcrun stapler.
#
set -euo pipefail

# ---- Configuration (override via environment) --------------------------------------
APP_NAME="${APP_NAME:-CocoGram}"
BUNDLE_ID="${BUNDLE_ID:-me.giannak.nick.cocogram}"
SHORT_VERSION="${SHORT_VERSION:-0.1.0}"
BUILD_VERSION="${BUILD_VERSION:-1}"
MIN_MACOS="${MIN_MACOS:-15.0}"

# Developer ID Application identity (from `security find-identity -v -p codesigning`).
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: D Ebert (NU5AXB7577)}"

# App Store Connect API key for notarization. Shared out-of-band; kept out of the repo.
NOTARY_KEY="${NOTARY_KEY:-$HOME/Downloads/AuthKey_3449L7URA8.p8}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-3449L7URA8}"
NOTARY_ISSUER="${NOTARY_ISSUER:-69a6de76-1a6c-47e3-e053-5b8c7c11a4d1}"

SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"   # set to 1 to build+sign only (no Apple round-trip)

# ---- Paths -------------------------------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"
FRAMEWORKS_DIR="$CONTENTS/Frameworks"
BIN_SRC="$ROOT/.build/release/$APP_NAME"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---- 1. Release build --------------------------------------------------------------
say "Building release binary (static TDLib relink — this is the slow part)"
swift build -c release
[ -f "$BIN_SRC" ] || { echo "ERROR: release binary not found at $BIN_SRC" >&2; exit 1; }

# ---- 2. Assemble the .app skeleton -------------------------------------------------
say "Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RES_DIR" "$FRAMEWORKS_DIR"
cp "$BIN_SRC" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
cp -R "$ROOT/.build/release/ogg.framework" "$FRAMEWORKS_DIR/"
cp -R "$ROOT/.build/release/opus.framework" "$FRAMEWORKS_DIR/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$APP_NAME"

# ---- 3. Info.plist -----------------------------------------------------------------
say "Writing Info.plist"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key>         <string>$BUILD_VERSION</string>
    <key>LSMinimumSystemVersion</key>  <string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.social-networking</string>
    <key>NSMicrophoneUsageDescription</key> <string>CocoGram uses the microphone to record voice messages.</string>
</dict>
</plist>
PLIST

# ---- 4. Icon -----------------------------------------------------------------------
say "Generating placeholder app icon"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/scripts/make_icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$RES_DIR/AppIcon.icns"
rm -rf "$ICONSET"

# ---- 5. Code signing (hardened runtime, required for notarization) -----------------
say "Code signing with: $SIGN_IDENTITY"
codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$FRAMEWORKS_DIR/ogg.framework"
codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$FRAMEWORKS_DIR/opus.framework"
codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$APP"

say "Verifying signature"
codesign --verify --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority=Developer ID|flags" || true

if [ "$SKIP_NOTARIZE" = "1" ]; then
    say "SKIP_NOTARIZE=1 — stopping after sign. App at: $APP"
    exit 0
fi

# ---- 6. Notarize -------------------------------------------------------------------
[ -f "$NOTARY_KEY" ] || { echo "ERROR: notary key not found at $NOTARY_KEY" >&2; exit 1; }
say "Zipping for notarization"
ZIP="$DIST/$APP_NAME.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

say "Submitting to Apple notary service (waits for result)"
xcrun notarytool submit "$ZIP" \
    --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
    --wait

# ---- 7. Staple + final gatekeeper check --------------------------------------------
say "Stapling notarization ticket"
xcrun stapler staple "$APP"

say "Final Gatekeeper assessment"
spctl -a -t exec -vvv "$APP"
xcrun stapler validate "$APP"

say "DONE — distributable app at: $APP"
echo "Ship $ZIP (re-zip after stapling for distribution):"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "  -> $ZIP"
