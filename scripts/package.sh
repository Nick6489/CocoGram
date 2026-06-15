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
# The Developer ID TEAM the signature must belong to. Both build machines must use the SAME team
# so a cross-machine update never resets an existing user's microphone (TCC) grant. Verified post-sign.
EXPECTED_TEAM="${EXPECTED_TEAM:-NU5AXB7577}"

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

# ---- 5. Code signing — RECORDABLE BY CONSTRUCTION ----------------------------------
# CONTRACT (non-negotiable): this script MUST produce a binary that records audio on the machine
# that built it — EVERY time, on EVERY workstation — regardless of whether a Developer ID cert, the
# notary .p8/issuer, notarization, or stapling are present or succeed. Recording needs exactly three
# things, and ONLY these three are hard requirements (the "recordability gate", §5a):
#   1. NSMicrophoneUsageDescription in Info.plist        (so TCC can prompt)
#   2. the com.apple.security.device.audio-input entitlement  (hardened runtime blocks the mic without it)
#   3. a valid code signature                             (even AD-HOC is fine for local recording)
# Everything else — the Developer ID identity, a matching team, notarization, stapling — is
# best-effort DISTRIBUTION polish (Gatekeeper trust + cross-machine TCC-grant persistence). Its
# absence or failure WARNS but NEVER aborts a recordable build. This is the fix for "records on one
# workstation but not the other": recordability no longer rides on the signing/notarization pipeline.
ENTITLEMENTS="$ROOT/CocoGram.entitlements"
[ -f "$ENTITLEMENTS" ] || { echo "ERROR: entitlements not found at $ENTITLEMENTS" >&2; exit 1; }

# Sign helper: hardened runtime + the audio-input entitlement, with the given identity. The app is
# always entitled (so it records under the hardened runtime even when ad-hoc). --timestamp needs a
# real cert + network, so it is used only for a real Developer ID identity; ad-hoc can't timestamp.
sign_with() {
    local id="$1"
    local ts=(--timestamp)
    [ "$id" = "-" ] && ts=(--timestamp=none)
    codesign --force --options runtime "${ts[@]}" --sign "$id" "$FRAMEWORKS_DIR/ogg.framework" || return 1
    codesign --force --options runtime "${ts[@]}" --sign "$id" "$FRAMEWORKS_DIR/opus.framework" || return 1
    codesign --force --options runtime "${ts[@]}" --entitlements "$ENTITLEMENTS" --sign "$id" "$APP" || return 1
}

# Pick the identity: prefer the configured Developer ID; fall back to AD-HOC so a machine without
# that cert (or with a locked keychain) STILL yields a recordable binary. Set FORCE_ADHOC=1 to test
# the fallback path deliberately.
SIGN_MODE="developer-id"
if [ "${FORCE_ADHOC:-0}" = "1" ] || ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    [ "${FORCE_ADHOC:-0}" = "1" ] && echo "NOTE: FORCE_ADHOC=1 — signing ad-hoc on purpose." \
        || { echo "WARNING: Developer ID identity not found on this machine:" >&2; echo "           '$SIGN_IDENTITY'" >&2; }
    echo "         Signing AD-HOC. The app WILL record (usage string + entitlement are applied); it" >&2
    echo "         just won't be notarized/Gatekeeper-trusted for distribution to OTHER machines." >&2
    echo "         Build on a machine with the Developer ID cert for a distributable, notarized build." >&2
    SIGN_IDENTITY="-"
    SIGN_MODE="adhoc"
fi

say "Code signing ($SIGN_MODE) with: $SIGN_IDENTITY"
if ! sign_with "$SIGN_IDENTITY"; then
    if [ "$SIGN_MODE" != "adhoc" ]; then
        echo "WARNING: signing with the Developer ID identity failed — retrying AD-HOC so the build" >&2
        echo "         still records. (A distributable build needs a machine where signing succeeds.)" >&2
        SIGN_MODE="adhoc"; SIGN_IDENTITY="-"
        sign_with "-" || { echo "ERROR: even ad-hoc signing failed — codesign is broken; no runnable binary." >&2; exit 1; }
    else
        echo "ERROR: ad-hoc signing failed — codesign is broken; no runnable binary." >&2
        exit 1
    fi
fi
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority|flags" || true

# ---- 5a. RECORDABILITY GATE — the ONLY hard requirements ----------------------------
# If these three pass, the app records on this machine. Each is a hard failure: a build that can't
# record is worthless. (Distribution polish in §5b/§6 only warns.)
say "Recordability gate (the build's contract: this app MUST be able to record on this machine)"
codesign --verify --strict --verbose=2 "$APP" \
    || { echo "ERROR: signature invalid — the app won't launch or record." >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Print :NSMicrophoneUsageDescription" "$CONTENTS/Info.plist" >/dev/null 2>&1 \
    || { echo "ERROR: NSMicrophoneUsageDescription missing — TCC would never prompt for the mic." >&2; exit 1; }
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.device.audio-input" \
    || { echo "ERROR: audio-input entitlement missing — the hardened runtime would block the mic." >&2; exit 1; }
echo "  RECORDABLE ✓  (valid signature + mic usage string + audio-input entitlement; mode=$SIGN_MODE)"

# ---- 5b. Distribution polish: team consistency (WARN only, never abort) --------------
# A matching team lets an existing user KEEP their mic TCC grant across an update (TCC keys the grant
# to the team-scoped designated requirement) and preserves Gatekeeper update trust. A team change (or
# an ad-hoc build) costs an existing user at most ONE mic re-grant — it does NOT stop recording — so
# this only WARNS. It does NOT touch the Telegram login session, which lives at a fixed Application
# Support path independent of the signature (see SESSION_PERSISTENCE_INVARIANT.md).
SIGNED_TEAM="$(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [ "$SIGN_MODE" = "adhoc" ]; then
    echo "NOTE: ad-hoc build (no team). Records on THIS machine. For a distributable update that"
    echo "      preserves existing users' mic grant, build where the '$EXPECTED_TEAM' Developer ID cert lives."
elif [ -n "$SIGNED_TEAM" ] && [ "$SIGNED_TEAM" != "$EXPECTED_TEAM" ]; then
    echo "WARNING: signed team '$SIGNED_TEAM' != expected '$EXPECTED_TEAM'. Existing users may need to" >&2
    echo "         re-grant the mic ONCE after updating. Recording still works; this is a persistence note." >&2
else
    echo "  signing team: ${SIGNED_TEAM:-<none>} (matches expected — existing users keep their mic grant)"
fi

# ---- 5c. Refresh LaunchServices so the freshly-built app shows its icon -------------
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

# ---- 6. Distribution: notarize + staple (BEST-EFFORT — never blocks a recordable build) ----
# The app already records (the recordability gate passed). Notarization/stapling only add Gatekeeper
# trust for distribution to OTHER machines. Every problem here WARNS and exits 0 with the signed,
# recordable app in place — it never fails the build. (notarytool/stapler are invoked under `if !`
# so `set -e` can't turn an Apple-side or network failure into a dead build.)
if [ "$SKIP_NOTARIZE" = "1" ]; then
    say "SKIP_NOTARIZE=1 — done after signing. The app records now. App at: $APP"
    exit 0
fi
if [ "$SIGN_MODE" = "adhoc" ]; then
    say "Ad-hoc build — skipping notarization (ad-hoc can't be notarized). The app RECORDS on this machine."
    echo "  For a distributable, notarized build, run on a machine with the Developer ID cert."
    exit 0
fi
if [ ! -f "$NOTARY_KEY" ]; then
    say "Notary key not found at: $NOTARY_KEY — skipping notarization. The app is signed and RECORDS."
    echo "  Set NOTARY_KEY / NOTARY_KEY_ID / NOTARY_ISSUER to notarize for distribution."
    exit 0
fi

say "Zipping for notarization"
ZIP="$DIST/$APP_NAME.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

say "Submitting to Apple notary service (waits for result)"
if ! xcrun notarytool submit "$ZIP" \
        --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait; then
    echo "WARNING: notarization failed (network / credentials / Apple service). The app is signed and" >&2
    echo "         RECORDS locally; it just isn't Gatekeeper-trusted for distribution yet. App at: $APP" >&2
    exit 0
fi

say "Stapling notarization ticket"
if ! xcrun stapler staple "$APP"; then
    echo "WARNING: stapling failed. The app is notarized + RECORDS; the distribution copy is unstapled" >&2
    echo "         (Gatekeeper verifies online on first launch). App at: $APP" >&2
    exit 0
fi

say "Final Gatekeeper assessment"
spctl -a -t exec -vvv "$APP" || echo "WARNING: spctl reported an issue (the app still records)." >&2
xcrun stapler validate "$APP" || true

say "DONE — distributable app at: $APP"
echo "Ship $ZIP (re-zip after stapling for distribution):"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "  -> $ZIP"
