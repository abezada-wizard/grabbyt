#!/bin/bash
# Compila Grabbyt en release y arma build/Grabbyt.app (firma ad-hoc).
# Uso: ./scripts/build-app.sh [--install]   (--install lo copia a /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Grabbyt.app"
echo "▸ Compilando (release, arm64)…"
swift build -c release --arch arm64 --product Grabbyt 2>&1 | grep -vE "ld: warning" || true
BIN="$(swift build -c release --arch arm64 --product Grabbyt --show-bin-path)/Grabbyt"
[ -x "$BIN" ] || { echo "No se encontró el binario"; exit 1; }

echo "▸ Armando $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Grabbyt"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ ! -f build/AppIcon.icns ]; then
  swift scripts/make-icon.swift build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Firmando (ad-hoc)…"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"

if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/Grabbyt.app
  cp -R "$APP" /Applications/
  echo "✔ Instalado en /Applications/Grabbyt.app"
else
  echo "✔ Listo: $APP"
fi
