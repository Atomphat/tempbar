#!/bin/zsh
# สร้าง build/TempBar.app จาก source
#   ./make-app.sh              build เฉพาะ CPU ของเครื่องนี้ (เร็ว)
#   ./make-app.sh --universal  build ทั้ง Intel + Apple Silicon (ใช้ตอนออก release)
set -e
cd "${0:A:h}"
VERSION=${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}
VERSION=${VERSION:-1.0.0}
APP=build/TempBar.app
rm -rf build; mkdir -p "$APP/Contents/MacOS"

if [[ "$1" == "--universal" ]]; then
  swiftc -O -target x86_64-apple-macos11 TempBar.swift -o build/TempBar-x86_64
  swiftc -O -target arm64-apple-macos11 TempBar.swift -o build/TempBar-arm64
  lipo -create build/TempBar-x86_64 build/TempBar-arm64 -output "$APP/Contents/MacOS/TempBar"
  rm build/TempBar-x86_64 build/TempBar-arm64
else
  swiftc -O TempBar.swift -o "$APP/Contents/MacOS/TempBar"
fi

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TempBar</string>
  <key>CFBundleIdentifier</key><string>com.atom.tempbar</string>
  <key>CFBundleExecutable</key><string>TempBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PL
codesign --force -s - "$APP"
echo "สร้างแล้ว: ${APP:A} (v$VERSION)"
