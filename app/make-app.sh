#!/usr/bin/env bash
# Собирает agent-heart.app. По умолчанию кладёт в app/build/.
#   ./make-app.sh              — собрать
#   ./make-app.sh /Applications — собрать и положить туда
set -euo pipefail
cd "$(dirname "$0")"

DEST="${1:-$PWD/build}"
APP="$DEST/agent-heart.app"
BUNDLE_ID="dev.agentheart.app"
VERSION="0.1.0"

echo "==> сборка (release)"
swift build -c release

echo "==> иконка"
TMP_ICON="$(mktemp -d)"
swift Tools/make-icon.swift "$TMP_ICON" >/dev/null
iconutil -c icns "$TMP_ICON/AppIcon.iconset" -o "$TMP_ICON/AppIcon.icns"

echo "==> бандл: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/AgentHeart "$APP/Contents/MacOS/agent-heart"
cp "$TMP_ICON/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Прайс-лист общий с анализатором — кладём копию внутрь бандла,
# чтобы приложение работало и без репозитория рядом.
cp ../shared/prices.json "$APP/Contents/Resources/prices.json"
rm -rf "$TMP_ICON"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>agent-heart</string>
  <key>CFBundleDisplayName</key><string>agent-heart</string>
  <key>CFBundleExecutable</key><string>agent-heart</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc подпись: для локального запуска достаточно, нотаризация нужна
# только если раздавать приложение другим машинам.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "   (подпись не удалась — не критично)"

echo "==> готово: $APP"
