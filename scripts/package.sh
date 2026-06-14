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

# ---- 4. Icon (ALWAYS bundled) ------------------------------------------------------
# Render a fresh icon from scripts/make_icon.swift; if that fails for any reason, fall back
# to the committed Resources/AppIcon.icns. Then HARD-VERIFY the icon actually landed in the
# bundle and is a valid .icns — packaging aborts rather than ship an icon-less app. The
# Info.plist above already declares CFBundleIconFile = AppIcon.
say "Generating app icon"
ICON_DST="$RES_DIR/AppIcon.icns"
ICON_FALLBACK="$ROOT/Resources/AppIcon.icns"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
if swift "$ROOT/scripts/make_icon.swift" "$ICONSET" && iconutil -c icns "$ICONSET" -o "$ICON_DST" 2>/dev/null; then
    echo "  rendered AppIcon.icns from scripts/make_icon.swift"
else
    echo "  WARNING: icon generation failed — falling back to committed icon" >&2
    [ -f "$ICON_FALLBACK" ] || { echo "ERROR: icon generation failed and no committed fallback at $ICON_FALLBACK" >&2; exit 1; }
    cp "$ICON_FALLBACK" "$ICON_DST"
fi
rm -rf "$ICONSET"

# Always-bundled guarantee: the icon must exist, be non-empty, and be a real .icns.
[ -s "$ICON_DST" ] || { echo "ERROR: app icon missing from bundle at $ICON_DST" >&2; exit 1; }
if ! iconutil -c iconset "$ICON_DST" -o "$DIST/.icon-verify.iconset" >/dev/null 2>&1; then
    echo "ERROR: bundled AppIcon.icns is not a valid icns" >&2
    exit 1
fi
rm -rf "$DIST/.icon-verify.iconset"
echo "  app icon bundled at Contents/Resources/AppIcon.icns ($(du -h "$ICON_DST" | cut -f1 | tr -d ' '))"

# ---- 4b. Bundle UI sound effects ---------------------------------------------------
# Copied into Resources/Sounds BEFORE signing so they are sealed by the app signature
# (and thus survive notarization/stapling). The app loads them via
# Bundle.main/Resources/Sounds; `swift run` uses the SPM resource bundle instead.
say "Bundling sound effects"
SOUNDS_SRC="$ROOT/Sources/CocoGram/Sounds"
SOUNDS_DST="$RES_DIR/Sounds"
[ -d "$SOUNDS_SRC" ] || { echo "ERROR: sounds source not found at $SOUNDS_SRC" >&2; exit 1; }
rm -rf "$SOUNDS_DST"
mkdir -p "$SOUNDS_DST"
cp "$SOUNDS_SRC"/*.m4a "$SOUNDS_DST"/
SOUND_COUNT=$(ls -1 "$SOUNDS_DST"/*.m4a 2>/dev/null | wc -l | tr -d ' ')
[ "$SOUND_COUNT" -gt 0 ] || { echo "ERROR: no sound files were bundled" >&2; exit 1; }
echo "  bundled $SOUND_COUNT sound file(s) into Resources/Sounds"

# ---- 5. Code signing (hardened runtime, required for notarization) -----------------
# The app gets the audio-input entitlement; the hardened runtime blocks the microphone
# without it even though Info.plist declares NSMicrophoneUsageDescription. Frameworks are
# signed without entitlements (they don't request resources).
ENTITLEMENTS="$ROOT/CocoGram.entitlements"
[ -f "$ENTITLEMENTS" ] || { echo "ERROR: entitlements not found at $ENTITLEMENTS" >&2; exit 1; }
say "Code signing with: $SIGN_IDENTITY"
codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$FRAMEWORKS_DIR/ogg.framework"
codesign --force --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$FRAMEWORKS_DIR/opus.framework"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$APP"

say "Verifying signature"
codesign --verify --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority=Developer ID|flags" || true
say "Verifying microphone entitlement is present"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.device.audio-input" \
    && echo "  audio-input entitlement: OK" \
    || { echo "ERROR: audio-input entitlement missing from signed app" >&2; exit 1; }

# ---- 5b. Refresh LaunchServices so the freshly-built app shows its icon -------------
# Re-register the bundle and bump its mtime so LaunchServices re-reads the just-signed icon
# rather than a stale record from an earlier build at this same path. NOTE: this does NOT bust
# a poisoned iconservices RENDER cache from prior builds — if Finder still shows a generic or
# wrong icon for a path you've rebuilt many times, clear the icon cache once (see README/run):
#   sudo rm -rf /Library/Caches/com.apple.iconservices.store && sudo killall iconservicesagent && killall Dock Finder
# Fresh installs (a new machine, or /Applications) always show the icon correctly.
say "Refreshing LaunchServices registration"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
touch -c "$APP"
echo "  re-registered with LaunchServices"

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
