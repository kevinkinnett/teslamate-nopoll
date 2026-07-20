#!/usr/bin/env bash
# Generate the certificate chain the CAR uses to reach your telemetry server.
#
# This is a SELF-SIGNED chain and that is correct: the car validates your
# server against the CA you register with Tesla in fleet_telemetry_config,
# not against a public CA. Do NOT use Let's Encrypt here.
#
# (Let's Encrypt IS needed separately, on :443, for the partner-domain
# public key -- that is handled by the `wellknown` service.)
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "ERROR: .env not found (cp .env.example .env)"; exit 1; }
# shellcheck disable=SC1091
set -a; . ./.env; set +a
: "${DOMAIN:?DOMAIN must be set in .env}"

OUT=certs
mkdir -p "$OUT"

if [ -f "$OUT/vehicle_device.CA.cert" ]; then
  echo "certs/ already populated -- refusing to overwrite."
  echo "Delete certs/ first if you really want to regenerate."
  echo "NOTE: regenerating the CA means re-running scripts/register-telemetry.sh,"
  echo "      because the car validates against the CA you registered."
  exit 1
fi

echo "==> CA (EC P-256, 10 years)"
openssl ecparam -name prime256v1 -genkey -noout -out "$OUT/vehicle_device.CA.key"
openssl req -x509 -new -nodes -key "$OUT/vehicle_device.CA.key" \
  -sha256 -days 3650 -out "$OUT/vehicle_device.CA.cert" \
  -subj "/CN=${DOMAIN}-telemetry-CA"

echo "==> server key + CSR (SAN=${DOMAIN})"
openssl ecparam -name prime256v1 -genkey -noout -out "$OUT/vehicle_device.app.key"
openssl req -new -key "$OUT/vehicle_device.app.key" \
  -out "$OUT/vehicle_device.app.csr" -subj "/CN=${DOMAIN}"

cat > "$OUT/app.ext" <<EOF
subjectAltName = DNS:${DOMAIN}
extendedKeyUsage = serverAuth
EOF

echo "==> sign server cert with the CA"
openssl x509 -req -in "$OUT/vehicle_device.app.csr" \
  -CA "$OUT/vehicle_device.CA.cert" -CAkey "$OUT/vehicle_device.CA.key" \
  -CAcreateserial -out "$OUT/vehicle_device.app.cert" \
  -days 3650 -sha256 -extfile "$OUT/app.ext"

rm -f "$OUT/vehicle_device.app.csr" "$OUT/app.ext" "$OUT/vehicle_device.CA.srl"

# fleet-telemetry runs as a NON-ROOT user and must be able to read the server
# key. The CA key is NOT mounted into the container and stays private.
chmod 644 "$OUT/vehicle_device.app.key" "$OUT/vehicle_device.app.cert" "$OUT/vehicle_device.CA.cert"
chmod 600 "$OUT/vehicle_device.CA.key"

echo
openssl verify -CAfile "$OUT/vehicle_device.CA.cert" "$OUT/vehicle_device.app.cert"
echo
echo "Done. Register certs/vehicle_device.CA.cert with Tesla via"
echo "scripts/register-telemetry.sh (it is sent as the config 'ca' field)."
echo "Keep certs/vehicle_device.CA.key private -- it is never mounted anywhere."
