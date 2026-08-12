#!/bin/bash
# Compila o Zeca (Release) e empacota build/Zeca.dmg com atalho pra /Applications.
# Uso: scripts/package-dmg.sh  (sem argumentos)
# Com SIGN_IDENTITY no ambiente assina com Developer ID; com as credenciais
# NOTARY_* tambem notariza e grampeia o ticket no app. Sem nada, build adhoc.
set -euo pipefail
cd "$(dirname "$0")/.."

# Assinar durante o build nao rola: os plugins do SPM (mlx) exigem team proprio.
# O build sai sem assinatura e o bundle e assinado por fora, de dentro pra fora.
xcodebuild -project Zeca.xcodeproj -scheme Zeca -configuration Release build \
  -derivedDataPath build \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  ${MARKETING_VERSION:+MARKETING_VERSION="$MARKETING_VERSION"} \
  -quiet

APP="build/Build/Products/Release/Zeca.app"
OUT="build/Zeca.dmg"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  find "$APP/Contents/Frameworks" \( -name "*.dylib" -o -name "*.framework" \) -maxdepth 1 2>/dev/null |
    while read -r item; do
      codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$item"
    done
  codesign --force --options runtime --timestamp \
    --entitlements Zeca.entitlements --sign "$SIGN_IDENTITY" "$APP"
fi

if [[ -n "${SIGN_IDENTITY:-}" && -n "${NOTARY_KEY_ID:-}" ]]; then
  KEY=$(mktemp)
  printf '%s' "$NOTARY_KEY_P8" > "$KEY"
  ditto -c -k --keepParent "$APP" build/notarize.zip
  xcrun notarytool submit build/notarize.zip \
    --key "$KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
  xcrun stapler staple "$APP"
  rm -f "$KEY" build/notarize.zip
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Zeca" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
echo "OK: $OUT ($(du -h "$OUT" | cut -f1))"
