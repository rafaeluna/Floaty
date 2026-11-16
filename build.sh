#!/bin/bash
# Builds Floaty.app, signs it, and relaunches it.
#   ./build.sh           build, sign, relaunch
#   ./build.sh --no-run  build and sign only
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Floaty.app"
IDENTITY="Floaty Dev"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Floaty" "$APP/Contents/MacOS/Floaty"
cp Assets/Floaty.icns "$APP/Contents/Resources/Floaty.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Floaty</string>
  <key>CFBundleDisplayName</key><string>Floaty</string>
  <key>CFBundleIdentifier</key><string>app.floaty.Floaty</string>
  <key>CFBundleExecutable</key><string>Floaty</string>
  <key>CFBundleIconFile</key><string>Floaty</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.2</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "warning: '$IDENTITY' not found (run scripts/setup-signing.sh); using ad-hoc signature"
  codesign --force --sign - "$APP"
fi

if [[ "${1:-}" != "--no-run" ]]; then
  pkill -x Floaty 2>/dev/null || true
  sleep 0.3
  open "$APP"
fi
echo "Built $APP"
