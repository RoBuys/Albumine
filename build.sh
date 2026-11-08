#!/bin/zsh
# Compile Albumine et crée Albumine.app dans le dossier courant.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="Albumine.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Albumine "$APP/Contents/MacOS/Albumine"
[ -f Resources/AppIcon.icns ] || swift Resources/make-icon.swift Resources
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Albumine</string>
  <key>CFBundleDisplayName</key><string>Albumine</string>
  <key>CFBundleIdentifier</key><string>local.albumine</string>
  <key>CFBundleExecutable</key><string>Albumine</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>100</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Robert Buys — licence MIT</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "✅ $APP prêt"
