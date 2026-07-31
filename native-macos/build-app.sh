#!/bin/bash
# ClaudeUsageBar.app paketini olusturur.
#
# SwiftPM ciplak bir calistirilabilir uretir; macOS'un bunu "uygulama" olarak
# gormesi icin belirli bir klasor yapisi ve Info.plist gerekir. Bu betik onu
# kuruyor.
#
# Kullanim:  ./build-app.sh          -> ClaudeUsageBar.app uretir
#            ./build-app.sh --zip    -> ayrica dagitima hazir .zip uretir

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ClaudeUsageBar"
# Bundle identifier, macOS'un uygulamani benzersiz olarak tanidigi kimlik.
# Yayinlarken kendi alan adin/GitHub kullanici adinla degistir.
BUNDLE_ID="io.github.claudeusagebar"
VERSION="1.0.0"

APP_DIR="$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

echo "==> Release derlemesi"
swift build -c release

echo "==> $APP_DIR olusturuluyor"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp ".build/release/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"

# LSUIElement = "bu uygulamanin Dock simgesi ve menu cubugu menusu olmasin,
# sadece arka planda calissin". Menu cubugu uygulamalarinin olmazsa olmazi.
# (Kodda ayrica NSApp.setActivationPolicy(.accessory) var; ikisi birlikte
# uygulamanin acilista bir an bile Dock'ta gorunmemesini garantiliyor.)
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>          <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>                <string>Claude Kullanım</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>$VERSION</string>
    <key>CFBundleVersion</key>             <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>      <string>13.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSHighResolutionCapable</key>     <true/>
</dict>
</plist>
PLIST

# Imzasiz bir uygulama macOS'ta calismaz; en azindan ad-hoc imza sart.
# ("-s -" = ad-hoc, yani sertifikasiz imza. Developer ID sertifikan varsa
#  onun adini yazarak imzalayabilirsin: codesign -s "Developer ID Application: ...")
echo "==> Ad-hoc imzalaniyor"
codesign --force --deep -s - "$APP_DIR"

echo "==> Hazir: $APP_DIR"

if [[ "${1:-}" == "--zip" ]]; then
    ZIP="$APP_NAME-$VERSION-macos.zip"
    rm -f "$ZIP"
    # ditto, .app paketlerini bozmadan (sembolik baglar, izinler, genisletilmis
    # oznitelikler dahil) sikistiran macOS araci — duz "zip" bunlari kaybedebilir.
    ditto -c -k --keepParent "$APP_DIR" "$ZIP"
    echo "==> Dagitim paketi: $ZIP"
fi
