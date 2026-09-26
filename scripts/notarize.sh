#!/bin/bash
# Notariza y "grapa" el DMG para que macOS lo abra sin avisos.
# Uso: ./scripts/notarize.sh build/Grabbyt-x.y.z.dmg
# Requiere: APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD (contraseña de app de appleid.apple.com)
set -euo pipefail
DMG="$1"
echo "▸ Enviando a Apple para notarizar (tarda unos minutos)…"
xcrun notarytool submit "$DMG" \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" \
  --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "✔ $DMG notarizado"
