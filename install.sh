#!/bin/zsh
# ติดตั้ง TempBar ลง ~/Applications และตั้งให้เปิดเองตอน login
#   curl -fsSL https://raw.githubusercontent.com/Atomphat/tempbar/main/install.sh | zsh
#   ./install.sh               (จากโฟลเดอร์ที่ clone มา: build จาก source ถ้ามี swiftc)
#   ./install.sh --uninstall   ถอนการติดตั้ง
set -e
REPO=Atomphat/tempbar
APP=~/Applications/TempBar.app
AGENT=~/Library/LaunchAgents/com.atom.tempbar.plist

pkill -x TempBar 2>/dev/null || true

if [[ "$1" == "--uninstall" ]]; then
  launchctl unload "$AGENT" 2>/dev/null || true
  rm -rf "$APP" "$AGENT"
  defaults delete com.atom.tempbar 2>/dev/null || true
  echo "ถอนการติดตั้ง TempBar แล้ว"
  exit 0
fi

mkdir -p ~/Applications ~/Library/LaunchAgents
SRC_DIR=${0:A:h}
if [[ "${0:t}" == install.sh && -f "$SRC_DIR/TempBar.swift" ]] && command -v swiftc >/dev/null; then
  echo "→ build จาก source..."
  "$SRC_DIR/make-app.sh"
  rm -rf "$APP"; cp -R "$SRC_DIR/build/TempBar.app" "$APP"
else
  echo "→ ดาวน์โหลด TempBar ล่าสุด..."
  TMP=$(mktemp -d)
  curl -fsSL "https://github.com/$REPO/releases/latest/download/TempBar.zip" -o "$TMP/TempBar.zip"
  ditto -x -k "$TMP/TempBar.zip" "$TMP"
  rm -rf "$APP"; mv "$TMP/TempBar.app" "$APP"
  rm -rf "$TMP"
fi
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

cat > "$AGENT" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.atom.tempbar</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>$APP</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PL

open "$APP"
echo "✓ ติดตั้งแล้ว: $APP (เปิดเองทุกครั้งที่ login)"
