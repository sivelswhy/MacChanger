#!/bin/sh
set -e
cd "$(dirname "$0")"
APP=MacChanger.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp icon/AppIcon.icns "$APP/Contents/Resources/"
if [ -n "$UNIVERSAL" ]; then
  swiftc -O -target arm64-apple-macos13 main.swift -o MacChanger-arm64
  swiftc -O -target x86_64-apple-macos13 main.swift -o MacChanger-x86_64
  lipo -create MacChanger-arm64 MacChanger-x86_64 -output "$APP/Contents/MacOS/MacChanger"
  rm MacChanger-arm64 MacChanger-x86_64
else
  swiftc -O main.swift -o "$APP/Contents/MacOS/MacChanger"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>MacChanger</string>
<key>CFBundleIdentifier</key><string>local.macchanger</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>MacChanger</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION:-1.0}</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
echo "OK -> $APP"
