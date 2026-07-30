#!/bin/bash
# Bundle a universal (arm64 + x86_64) release binary into petze.app
# VERSION=1.2.3 ./make-app.sh sets the bundle version (default 0.0.0-dev).
set -e
cd "$(dirname "$0")"
VERSION="${VERSION:-0.0.0-dev}"

if swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
    BIN=.build/apple/Products/Release/petze
else
    echo "universal build unavailable; falling back to host arch"
    swift build -c release
    BIN=.build/release/petze
fi

APP=petze.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/petze"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>petze</string>
    <key>CFBundleIdentifier</key><string>dev.alileza.petze</string>
    <key>CFBundleName</key><string>petze</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force --deep -s - "$APP"
echo "Built $APP — launch with: open $APP"
