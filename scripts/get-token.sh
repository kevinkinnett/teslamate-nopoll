#!/usr/bin/env bash
# Obtain a Tesla user token (authorization_code flow).
#
#   ./scripts/get-token.sh url                  print the login URL
#   ./scripts/get-token.sh '<callback-url>'     exchange the code
#
# Tesla authorization codes expire in about 60-90 seconds, so run the second
# command immediately after logging in. Open the URL in a PRIVATE window if
# your browser has a stale Tesla session.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "ERROR: .env not found (cp .env.example .env)"; exit 1; }
# shellcheck disable=SC1091
set -a; . ./.env; set +a
: "${TESLA_CLIENT_ID:?set in .env}"
: "${TESLA_CLIENT_SECRET:?set in .env}"
: "${TESLA_API_BASE:?set in .env}"

REDIRECT="http://localhost:3000/callback"
SCOPES="openid offline_access vehicle_device_data vehicle_location"
mkdir -p secrets

if [ $# -eq 0 ] || [ "${1:-}" = "url" ]; then
  ENC=${SCOPES// /%20}
  echo "1) Open in a PRIVATE/incognito window and sign in:"
  echo
  echo "https://auth.tesla.com/oauth2/v3/authorize?response_type=code&client_id=${TESLA_CLIENT_ID}&redirect_uri=http%3A%2F%2Flocalhost%3A3000%2Fcallback&scope=${ENC}&state=$(openssl rand -hex 8)&prompt=consent"
  echo
  echo "2) The browser will fail to load localhost:3000 -- that is expected."
  echo "   Copy the full URL from the address bar, then run:"
  echo "   ./scripts/get-token.sh '<that-url>'"
  exit 0
fi

CODE=$(printf '%s' "$1" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
[ -n "$CODE" ] || { echo "ERROR: no code= found in that URL"; exit 1; }

printf '%s' "$TESLA_CLIENT_SECRET" > secrets/.client_secret
chmod 600 secrets/.client_secret

RESP=$(curl -s -X POST https://auth.tesla.com/oauth2/v3/token \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "client_id=${TESLA_CLIENT_ID}" \
  --data-urlencode "client_secret@secrets/.client_secret" \
  --data-urlencode "code=${CODE}" \
  --data-urlencode "audience=${TESLA_API_BASE}" \
  --data-urlencode "redirect_uri=${REDIRECT}")

python3 - "$RESP" <<'PY'
import sys, json, base64
d = json.loads(sys.argv[1])
if d.get("error"):
    print("ERROR:", d.get("error"), d.get("error_description", "")); raise SystemExit(1)
acc, ref = d.get("access_token", ""), d.get("refresh_token", "")
p = acc.split(".")[1]; p += "=" * (-len(p) % 4)
print("scopes granted:", json.loads(base64.urlsafe_b64decode(p)).get("scp"))
open("secrets/.access_token", "w").write(acc)
open("secrets/.refresh_token", "w").write(ref)
print("saved secrets/.access_token and secrets/.refresh_token")
PY
chmod 600 secrets/.access_token secrets/.refresh_token 2>/dev/null || true
