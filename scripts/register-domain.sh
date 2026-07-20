#!/usr/bin/env bash
# Register ${DOMAIN} as a Tesla partner domain.
#
# PREREQUISITES -- Tesla enforces these in order, and each failure reports
# only the link it hit:
#
#   1. Your app's public key must be served at
#        https://${DOMAIN}/.well-known/appspecific/com.tesla.3p.public-key.pem
#      over HTTPS/443 with a PUBLICLY TRUSTED cert.
#      -> `docker compose up -d wellknown` does this (Let's Encrypt).
#      -> Verify from OUTSIDE your network before continuing.
#
#   2. https://${DOMAIN} must be listed under Allowed Origin(s) on your app
#      at developer.tesla.com. Tesla validates the domain AT THE MOMENT YOU
#      TYPE IT by fetching that URL -- so step 1 must already be live, or the
#      portal rejects it with "Domain is not valid".
#
# Only then will this script succeed.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "ERROR: .env not found"; exit 1; }
# shellcheck disable=SC1091
set -a; . ./.env; set +a
: "${TESLA_CLIENT_ID:?}"; : "${TESLA_CLIENT_SECRET:?}"
: "${TESLA_API_BASE:?}"; : "${DOMAIN:?}"

mkdir -p secrets
printf '%s' "$TESLA_CLIENT_SECRET" > secrets/.client_secret
chmod 600 secrets/.client_secret

echo "==> sanity: is the public key reachable over public HTTPS?"
URL="https://${DOMAIN}/.well-known/appspecific/com.tesla.3p.public-key.pem"
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$URL" || echo 000)
if [ "$CODE" != "200" ]; then
  echo "    got HTTP ${CODE} from ${URL}"
  echo "    Fix this first -- Tesla fetches exactly this URL."
  echo "    Common causes: port 443 not forwarded; ISP/router reserving 443"
  echo "    (AT&T gateways: the built-in 'ssl' preset silently fails -- use a"
  echo "    CUSTOM NAT/Gaming service entry instead); cert not yet issued."
  exit 1
fi
echo "    HTTP 200 OK"

echo "==> partner token (client_credentials)"
PT=$(curl -s -X POST https://auth.tesla.com/oauth2/v3/token \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${TESLA_CLIENT_ID}" \
  --data-urlencode "client_secret@secrets/.client_secret" \
  --data-urlencode "scope=openid vehicle_device_data vehicle_location" \
  --data-urlencode "audience=${TESLA_API_BASE}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
[ -n "$PT" ] || { echo "ERROR: could not obtain partner token"; exit 1; }

echo "==> POST /api/1/partner_accounts  domain=${DOMAIN}"
curl -s -X POST "${TESLA_API_BASE}/api/1/partner_accounts" \
  -H "Authorization: Bearer ${PT}" -H "Content-Type: application/json" \
  --data "{\"domain\":\"${DOMAIN}\"}" \
  | python3 -c '
import sys, json
d = json.load(sys.stdin)
if d.get("error"):
    print("  ERROR:", d["error"])
    print("  If it mentions \"allowed origin\", add https://<domain> to your app"
          "\n  Allowed Origins at developer.tesla.com and retry.")
    raise SystemExit(1)
r = d.get("response", {})
print("  registered:", r.get("domain"), "| app:", r.get("name"))
'
