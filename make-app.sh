#!/bin/bash
# Bundle the release binary into petze.app
set -e
cd "$(dirname "$0")"
swift build -c release
APP=petze.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/petze "$APP/Contents/MacOS/petze"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>petze</string>
    <key>CFBundleIdentifier</key><string>dev.alileza.petze</string>
    <key>CFBundleName</key><string>petze</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
echo "Built $APP — launch with: open $APP"
