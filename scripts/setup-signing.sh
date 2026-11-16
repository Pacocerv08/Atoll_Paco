#!/usr/bin/env bash
# Atoll_Paco: crea (una sola vez) un certificado de firma de código propio y
# gratuito en tu llavero, para firmar Atoll con él en vez de "ad-hoc".
#
# ¿Para qué? Con firma ad-hoc cada build nuevo es "otra app" para macOS: te
# vuelve a pedir Accesibilidad y el permiso del llavero (credenciales de TIDAL,
# API keys). Con un certificado fijo, macOS reconoce la app aunque recompiles.
#
# Uso:  ./scripts/setup-signing.sh
# Te va a pedir tu contraseña de la Mac (para confiar en el certificado).

set -euo pipefail

NAME="Atoll Paco Local"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
OPENSSL="/usr/bin/openssl"   # el de macOS (LibreSSL): su .p12 sí lo importa el llavero

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"${NAME}\""; then
    echo "✅ El certificado \"${NAME}\" ya existe. No hay nada que hacer."
    exit 0
fi

if security find-certificate -c "${NAME}" "${KEYCHAIN}" >/dev/null 2>&1; then
    echo "⚠️  Ya hay un certificado \"${NAME}\" en el llavero pero no es válido para firmar."
    echo "   Bórralo en Acceso a Llaveros (busca \"${NAME}\") y vuelve a correr este script."
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
P12_PASS="$("${OPENSSL}" rand -hex 16)"

cat > "${TMP}/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = codesign
prompt             = no

[ dn ]
CN = ${NAME}

[ codesign ]
basicConstraints     = critical, CA:false
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
EOF

echo "→ Generando certificado de firma \"${NAME}\" (válido 10 años)…"
"${OPENSSL}" req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -config "${TMP}/cert.cnf" \
    -keyout "${TMP}/key.pem" -out "${TMP}/cert.pem" 2>/dev/null

"${OPENSSL}" pkcs12 -export \
    -inkey "${TMP}/key.pem" -in "${TMP}/cert.pem" \
    -name "${NAME}" -out "${TMP}/identity.p12" -passout "pass:${P12_PASS}"

echo "→ Importándolo a tu llavero de inicio de sesión…"
security import "${TMP}/identity.p12" -k "${KEYCHAIN}" -P "${P12_PASS}" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "→ Marcándolo como confiable para firmar código (te pide tu contraseña)…"
security add-trusted-cert -r trustRoot -p codeSign -k "${KEYCHAIN}" "${TMP}/cert.pem"

if security find-identity -v -p codesigning | grep -q "\"${NAME}\""; then
    echo "✅ Listo. ./scripts/build-dmg.sh ya va a firmar con \"${NAME}\"."
    echo "   Después del próximo build, dale el permiso de Accesibilidad una última vez."
else
    echo "❌ El certificado se importó pero macOS no lo ve como válido para firmar."
    echo "   Pásale a Claude la salida de: security find-identity -p codesigning"
    exit 1
fi
