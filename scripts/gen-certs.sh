#!/usr/bin/env bash
# Generates every key and certificate the stack needs. Safe to re-run: existing
# material is kept unless you delete it. Reads DOMAIN from .env.
#
# There are three independent pieces of crypto here, and confusing them is the
# usual source of pain:
#
#   1. Application key pair  — your third-party app's identity. The PUBLIC key
#      is hosted at the .well-known path and registered with Tesla; the PRIVATE
#      key signs commands (via the vehicle-command proxy).
#
#   2. Telemetry CA + server cert — SELF-SIGNED, and that is correct. The car
#      validates your telemetry server against the CA you register with Tesla,
#      not against a public CA. No Let's Encrypt here.
#
#   3. Proxy TLS cert — a throwaway self-signed cert for the local
#      vehicle-command proxy's own HTTPS listener. Clients reach it with -k.
#
# (Let's Encrypt IS needed, but only for the :443 public-key endpoint, and that
# is handled automatically by the `wellknown` service — not by this script.)
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "ERROR: .env not found (cp .env.example .env)"; exit 1; }
# shellcheck disable=SC1091
set -a; . ./.env; set +a
: "${DOMAIN:?DOMAIN must be set in .env}"

CERTS=certs
PROXY=proxy
WK=wellknown/srv/.well-known/appspecific
mkdir -p "$CERTS" "$PROXY" "$WK"
chmod 700 "$PROXY" 2>/dev/null || true

# 1) APPLICATION KEY PAIR ----------------------------------------------------
if [ -f "$PROXY/private-key.pem" ]; then
  echo "==> app key pair exists ($PROXY/private-key.pem) — keeping it"
else
  echo "==> app key pair (EC P-256)"
  openssl ecparam -name prime256v1 -genkey -noout -out "$PROXY/private-key.pem"
  openssl ec -in "$PROXY/private-key.pem" -pubout \
    -out "$WK/com.tesla.3p.public-key.pem" 2>/dev/null
  # The vehicle-command image runs as a non-root user and must read the key;
  # 644 in a 700 directory keeps other local users out while letting the
  # container in via the bind mount. The public key is, of course, public.
  chmod 644 "$PROXY/private-key.pem" "$WK/com.tesla.3p.public-key.pem"
fi

# 2) PROXY TLS CERT ----------------------------------------------------------
if [ -f "$PROXY/tls-cert.pem" ]; then
  echo "==> proxy TLS cert exists — keeping it"
else
  echo "==> proxy TLS cert (self-signed, localhost)"
  # Two-step (ecparam then req -x509 -key) for portability across openssl
  # versions. This is a localhost cert reached with curl -k, so no SAN needed.
  openssl ecparam -name prime256v1 -genkey -noout -out "$PROXY/tls-key.pem"
  openssl req -x509 -new -nodes -key "$PROXY/tls-key.pem" -sha256 -days 3650 \
    -out "$PROXY/tls-cert.pem" -subj "/CN=localhost"
  chmod 644 "$PROXY/tls-key.pem" "$PROXY/tls-cert.pem"
fi

# 3) TELEMETRY CA + SERVER CERT ----------------------------------------------
if [ -f "$CERTS/vehicle_device.CA.cert" ]; then
  echo "==> telemetry CA + server cert exist — keeping them"
  echo "    (delete certs/ to regenerate; you must then re-run register-telemetry.sh,"
  echo "     because the car validates against the CA you registered.)"
else
  echo "==> telemetry CA (EC P-256, 10 years)"
  openssl ecparam -name prime256v1 -genkey -noout -out "$CERTS/vehicle_device.CA.key"
  openssl req -x509 -new -nodes -key "$CERTS/vehicle_device.CA.key" \
    -sha256 -days 3650 -out "$CERTS/vehicle_device.CA.cert" \
    -subj "/CN=${DOMAIN}-telemetry-CA"

  echo "==> telemetry server cert (SAN=${DOMAIN})"
  openssl ecparam -name prime256v1 -genkey -noout -out "$CERTS/vehicle_device.app.key"
  openssl req -new -key "$CERTS/vehicle_device.app.key" \
    -out "$CERTS/vehicle_device.app.csr" -subj "/CN=${DOMAIN}"
  cat > "$CERTS/app.ext" <<EOF
subjectAltName = DNS:${DOMAIN}
extendedKeyUsage = serverAuth
EOF
  openssl x509 -req -in "$CERTS/vehicle_device.app.csr" \
    -CA "$CERTS/vehicle_device.CA.cert" -CAkey "$CERTS/vehicle_device.CA.key" \
    -CAcreateserial -out "$CERTS/vehicle_device.app.cert" \
    -days 3650 -sha256 -extfile "$CERTS/app.ext"
  rm -f "$CERTS/vehicle_device.app.csr" "$CERTS/app.ext" "$CERTS/vehicle_device.CA.srl"

  # fleet-telemetry runs non-root -> server key must be readable (644);
  # the CA key is never mounted and stays private (600).
  chmod 644 "$CERTS/vehicle_device.app.key" "$CERTS/vehicle_device.app.cert" "$CERTS/vehicle_device.CA.cert"
  chmod 600 "$CERTS/vehicle_device.CA.key"
  openssl verify -CAfile "$CERTS/vehicle_device.CA.cert" "$CERTS/vehicle_device.app.cert"
fi

echo
echo "Done. Public key -> $WK/com.tesla.3p.public-key.pem"
echo "Register certs/vehicle_device.CA.cert with Tesla via scripts/register-telemetry.sh."
