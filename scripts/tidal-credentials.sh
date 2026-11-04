#!/usr/bin/env bash
# Atoll_Paco: guarda el Client ID y Client Secret de tu app de developer.tidal.com
# en el Keychain, para que Atoll baje portadas de TIDAL en alta resolución.
#
# Uso:  ./scripts/tidal-credentials.sh          (guardar o reemplazar)
#       ./scripts/tidal-credentials.sh --borrar (quitarlas)
#
# `security` te pide cada valor sin mostrarlo en pantalla ni dejarlo en el
# historial. La primera vez que Atoll las lea, macOS te va a preguntar si la
# dejas usar el Keychain: dale "Permitir siempre" (y otra vez tras recompilar).

set -euo pipefail

SERVICE="com.pacocerv08.AtollPaco.tidal"
APP="/Applications/Atoll.app"

if [ "${1:-}" = "--borrar" ]; then
    security delete-generic-password -s "${SERVICE}" -a client-id >/dev/null 2>&1 || true
    security delete-generic-password -s "${SERVICE}" -a client-secret >/dev/null 2>&1 || true
    echo "✅ Credenciales de TIDAL borradas del Keychain."
    exit 0
fi

TRUST=()
if [ -d "${APP}" ]; then
    TRUST=(-T "${APP}")
fi

echo "→ Pega el Client ID (te lo pide dos veces):"
security add-generic-password -U -s "${SERVICE}" -a client-id ${TRUST[@]+"${TRUST[@]}"} -w

echo "→ Pega el Client Secret (te lo pide dos veces):"
security add-generic-password -U -s "${SERVICE}" -a client-secret ${TRUST[@]+"${TRUST[@]}"} -w

echo "✅ Listo. Cierra y vuelve a abrir Atoll, y pon algo en TIDAL."
