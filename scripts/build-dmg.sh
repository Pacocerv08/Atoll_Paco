#!/usr/bin/env bash
# Atoll_Paco: compila la app en Release con firma ad-hoc (sin cuenta de Apple
# Developer) y arma build/Atoll.dmg para instalarla en tu Mac.
#
# Uso:  ./scripts/build-dmg.sh             (arma build/Atoll.dmg)
#       ./scripts/build-dmg.sh --instalar  (además la copia a /Applications y la abre)
#
# La primera vez que abras la app: clic derecho → Abrir (es firma ad-hoc,
# Gatekeeper no la reconoce). O: xattr -dr com.apple.quarantine /Applications/Atoll.app

set -euo pipefail

cd "$(dirname "$0")/.."

# Fuera del repo a propósito: si el repo vive en una carpeta sincronizada
# (iCloud/Drive/OneDrive en Documents), el sync le pega atributos extendidos a
# los archivos y codesign falla con "resource fork ... detritus not allowed".
# Termina en .noindex para que Spotlight/Apps no la indexen: si no, la copia del
# build aparece como una segunda "Atoll" junto a la de /Applications.
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/AtollPaco.noindex"
OLD_DERIVED="$HOME/Library/Developer/Xcode/DerivedData/AtollPaco"
INSTALL=false
[ "${1:-}" = "--instalar" ] && INSTALL=true

if [ -d "${OLD_DERIVED}" ]; then
    echo "→ Borrando el build viejo indexado (${OLD_DERIVED})…"
    rm -rf "${OLD_DERIVED}"
fi
APP="${DERIVED}/Build/Products/Release/Atoll.app"
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

# Firma: si existe el certificado propio (scripts/setup-signing.sh), se usa ese para
# que macOS reconozca la app entre builds (Accesibilidad y llavero no se vuelven a
# pedir). Si no, ad-hoc.
SIGN_NAME="Atoll Paco Local"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"${SIGN_NAME}\""; then
    SIGN_IDENTITY="${SIGN_NAME}"
    echo "→ Firmando con el certificado \"${SIGN_NAME}\"."
else
    SIGN_IDENTITY="-"
    echo "⚠️  Firma ad-hoc: macOS te volverá a pedir permisos tras cada build."
    echo "   Para evitarlo, corre una vez: ./scripts/setup-signing.sh"
fi

echo "→ Compilando (Release)… esto tarda unos minutos la primera vez."
xcodebuild build \
    -project DynamicIsland.xcodeproj \
    -scheme DynamicIsland \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "${DERIVED}" \
    -quiet \
    CODE_SIGN_IDENTITY="${SIGN_IDENTITY}" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM=""

if [ ! -d "${APP}" ]; then
    echo "❌ No se generó ${APP}. Revisa los errores de arriba."
    exit 1
fi

codesign --verify --verbose=1 "${APP}" || echo "⚠️  codesign --verify se quejó; la app igual puede abrir."

echo "→ Armando ${DMG}…"
STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT
ditto --norsrc --noextattr "${APP}" "${STAGING}/Atoll.app"
ln -s /Applications "${STAGING}/Applications"
mkdir -p "$(dirname "${DMG}")"
rm -f "${DMG}"
hdiutil create -volname "Atoll" -srcfolder "${STAGING}" -ov -format UDZO "${DMG}" >/dev/null

echo "✅ Listo: ${DMG}"

if [ "${INSTALL}" = true ]; then
    BUNDLE_ID="$(defaults read "${APP}/Contents/Info" CFBundleIdentifier)"
    DEST="/Applications/Atoll.app"
    if [ -d "${DEST}" ]; then
        DEST_ID="$(defaults read "${DEST}/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
        if [ "${DEST_ID}" != "${BUNDLE_ID}" ]; then
            echo "❌ ${DEST} es otra app (${DEST_ID:-desconocida}), no tu fork. No la toco."
            echo "   Si es la Atoll oficial y no la usas, mándala a la papelera y vuelve a correr."
            exit 1
        fi
        echo "→ Cerrando Atoll…"
        osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
        sleep 1
        rm -rf "${DEST}"
    fi
    echo "→ Instalando en ${DEST}…"
    ditto --norsrc --noextattr "${APP}" "${DEST}"
    xattr -dr com.apple.quarantine "${DEST}" 2>/dev/null || true
    open "${DEST}"
    echo "✅ Atoll instalada y abierta."
else
    echo "   Ábrelo, arrastra Atoll a Aplicaciones y la primera vez ábrela con clic derecho → Abrir."
    echo "   (O la próxima vez usa: ./scripts/build-dmg.sh --instalar)"
fi
