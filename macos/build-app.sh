#!/bin/bash
# Builds the ClaudeLimitBar.app bundle.
#
# SwiftPM produces a bare executable; macOS needs a specific folder
# structure and an Info.plist for it to be recognized as an "app". This
# script sets that up.
#
# Usage:  ./build-app.sh          -> produces ClaudeLimitBar.app
#         ./build-app.sh --zip    -> also produces a distributable .zip

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ClaudeLimitBar"
# Bundle identifier, the id macOS uses to uniquely recognize the app.
# Replace with your own domain/GitHub username if you publish your own build.
BUNDLE_ID="io.github.claudelimitbar"

# The version comes from the release tag, never from a line in this file.
# Held here as a literal, it had to be remembered separately every time a tag
# was pushed: the release would be titled v0.3.0 while the app inside it went
# on reporting 0.2.2, and nothing would complain. The release workflow passes
# VERSION in; a local build on a tagged commit picks the tag up by itself.
#
# Anywhere else there is no release to name, so it builds as 0.0.0 rather than
# borrowing a number that belongs to a real one.
if [[ -z "${VERSION:-}" ]]; then
    VERSION="$(git describe --tags --exact-match 2>/dev/null | sed 's/^v//' || true)"
fi
VERSION="${VERSION:-0.0.0}"

APP_DIR="$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

echo "==> Release build"
swift build -c release

echo "==> Creating $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp ".build/release/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
cp "Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

# LSUIElement = "this app has no Dock icon and no menu bar application
# menu, it just runs in the background" — essential for a menu bar app.
# (The code also sets NSApp.setActivationPolicy(.accessory); together the
# two guarantee the app never shows in the Dock, not even for a moment at launch.)
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>          <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>                <string>Claude Limit Bar</string>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>$VERSION</string>
    <key>CFBundleVersion</key>             <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>      <string>13.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSHighResolutionCapable</key>     <true/>
</dict>
</plist>
PLIST

# An unsigned app won't run on macOS; at minimum an ad-hoc signature is
# required. ("-s -" = ad-hoc, i.e. an unsigned/certificate-less signature.
# If you have a Developer ID certificate, sign with it by name instead:
# codesign -s "Developer ID Application: ...")
echo "==> Ad-hoc signing"
codesign --force --deep -s - "$APP_DIR"

echo "==> Ready: $APP_DIR"

if [[ "${1:-}" == "--zip" ]]; then
    ZIP="$APP_NAME-$VERSION-macos.zip"
    rm -f "$ZIP"
    # ditto is the macOS tool that compresses .app bundles without breaking
    # them (symlinks, permissions, extended attributes included) — a plain
    # "zip" can lose these.
    ditto -c -k --keepParent "$APP_DIR" "$ZIP"
    echo "==> Distribution package: $ZIP"
fi
