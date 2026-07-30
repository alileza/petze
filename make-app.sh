#!/bin/bash
# Bundle the release binary into batmon.app
set -e
cd "$(dirname "$0")"
swift build -c release
APP=batmon.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/batmon "$APP/Contents/MacOS/batmon"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>batmon</string>
    <key>CFBundleIdentifier</key><string>dev.alileza.batmon</string>
    <key>CFBundleName</key><string>batmon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
echo "Built $APP — launch with: open $APP"
