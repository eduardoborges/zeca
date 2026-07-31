#!/bin/bash
# Compila o ZecaAI (Release) e empacota build/ZecaAI.dmg com atalho pra /Applications.
# Uso: scripts/package-dmg.sh  (sem argumentos)
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild -project ZecaAI.xcodeproj -scheme ZecaAI -configuration Release build \
  -derivedDataPath build \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  ${MARKETING_VERSION:+MARKETING_VERSION="$MARKETING_VERSION"} \
  -quiet

APP="build/Build/Products/Release/ZecaAI.app"
OUT="build/ZecaAI.dmg"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Zeca AI" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
echo "OK: $OUT ($(du -h "$OUT" | cut -f1))"
