#!/usr/bin/env bash
# Atoll_Paco: compila la app en Release con firma ad-hoc (sin cuenta de Apple
# Developer) y arma build/Atoll.dmg para instalarla en tu Mac.
#
# Uso:  ./scripts/build-dmg.sh
#
# La primera vez que abras la app: clic derecho → Abrir (es firma ad-hoc,
# Gatekeeper no la reconoce). O: xattr -dr com.apple.quarantine /Applications/Atoll.app

set -euo pipefail

cd "$(dirname "$0")/.."

DERIVED="build/DerivedData"
APP="$DERIVED/Build/Products/Release/Atoll.app"
DMG="build/Atoll.dmg"

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "❌ No encuentro xcodebuild. Instala Xcode desde la App Store y ábrelo una vez."
    exit 1
fi

# Xcode 26+ ya no trae el compilador de Metal; SwiftTerm lo necesita para sus shaders.
if ! xcrun metal --version >/dev/null 2>&1; then
    echo "→ Falta el Metal Toolchain, bajándolo (una sola vez, tarda un rato)…"
    xcodebuild -downloadComponent MetalToolchain || {
        echo "❌ No se pudo bajar. Prueba: sudo xcodebuild -downloadComponent MetalToolchain"
        exit 1
    }
fi

if command -v git-lfs >/dev/null 2>&1; then
    echo "→ Bajando archivos de Git LFS (videos de AirPods)…"
    git lfs pull
else
    echo "⚠️  No tienes git-lfs (brew install git-lfs). Las animaciones .mov pueden salir rotas."
fi

echo "→ Compilando (Release, firma ad-hoc)… esto tarda unos minutos la primera vez."
xcodebuild build \
    -project DynamicIsland.xcodeproj \
    -scheme DynamicIsland \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED" \
    -quiet \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM=""

if [ ! -d "$APP" ]; then
    echo "❌ No se generó $APP. Revisa los errores de arriba."
    exit 1
fi

codesign --verify --verbose=1 "$APP" || echo "⚠️  codesign --verify se quejó; la app igual puede abrir."

echo "→ Armando $DMG…"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Atoll" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

echo "✅ Listo: $DMG"
echo "   Ábrelo, arrastra Atoll a Aplicaciones y la primera vez ábrela con clic derecho → Abrir."
