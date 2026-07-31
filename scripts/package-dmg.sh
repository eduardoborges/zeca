#!/bin/bash
# Empacota o ZecaAI.app num DMG com atalho pra /Applications.
# Uso: scripts/package-dmg.sh <caminho/ZecaAI.app> [saida.dmg]
set -euo pipefail

APP="${1:?uso: package-dmg.sh <ZecaAI.app> [saida.dmg]}"
OUT="${2:-build/ZecaAI.dmg}"
mkdir -p "$(dirname "$OUT")"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Zeca AI" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
echo "OK: $OUT ($(du -h "$OUT" | cut -f1))"
