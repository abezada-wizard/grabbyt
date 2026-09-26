#!/bin/bash
# Compila Grabbyt en release y arma build/Grabbyt.app (firma ad-hoc).
# Uso: ./scripts/build-app.sh [--install] [--dmg]
#   --install  la copia a /Applications
#   --dmg      además crea build/Grabbyt-<versión>.dmg (con acceso directo a Aplicaciones)
# Variables opcionales: GRABBYT_VERSION (p. ej. v1.2.3), GRABBYT_REPOSITORY (usuario/repo)
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0; DMG=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --dmg) DMG=1 ;;
  esac
done

echo "▸ Compilando (release, arm64)…"
swift build -c release --arch arm64 --product Grabbyt 2>&1 | grep -vE "ld: warning" || true
BIN="$(swift build -c release --arch arm64 --product Grabbyt --show-bin-path)/Grabbyt"
[ -x "$BIN" ] || { echo "No se encontró el binario"; exit 1; }

# Se arma fuera del proyecto: si está en iCloud Drive (Documentos/Escritorio), el sistema agrega
# atributos extendidos al .app que hacen fallar codesign.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/grabbyt-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Grabbyt.app"

echo "▸ Armando Grabbyt.app…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build
cp "$BIN" "$APP/Contents/MacOS/Grabbyt"
cp Resources/Info.plist "$APP/Contents/Info.plist"
PLIST="$APP/Contents/Info.plist"
if [ -n "${GRABBYT_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${GRABBYT_VERSION#v}" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER:-1}" "$PLIST"
fi
# Repo de GitHub para el aviso de actualizaciones: GRABBYT_REPOSITORY o el remote "origin".
REPO="${GRABBYT_REPOSITORY:-$(git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##' || true)}"
/usr/libexec/PlistBuddy -c "Set :GrabbytRepository ${REPO}" "$PLIST"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"

if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make-icon.swift Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Firmando (ad-hoc)…"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify "$APP"

rm -rf build/Grabbyt.app
ditto "$APP" build/Grabbyt.app
echo "✔ build/Grabbyt.app (v$VERSION)"

if [ "$DMG" = 1 ]; then
  echo "▸ Creando DMG…"
  DMG_DIR="$STAGE/dmg"
  mkdir -p "$DMG_DIR"
  ditto "$APP" "$DMG_DIR/Grabbyt.app"
  ln -s /Applications "$DMG_DIR/Aplicaciones"
  OUT="build/Grabbyt-$VERSION.dmg"
  rm -f "$OUT"
  hdiutil create -volname "Grabbyt" -srcfolder "$DMG_DIR" -ov -format UDZO "$STAGE/Grabbyt.dmg" >/dev/null
  cp "$STAGE/Grabbyt.dmg" "$OUT"
  echo "✔ $OUT"
fi

if [ "$INSTALL" = 1 ]; then
  rm -rf /Applications/Grabbyt.app
  ditto "$APP" /Applications/Grabbyt.app
  echo "✔ Instalado en /Applications/Grabbyt.app"
fi
