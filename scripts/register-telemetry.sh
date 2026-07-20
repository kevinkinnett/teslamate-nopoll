#!/usr/bin/env bash
# Configure the car to stream telemetry to your server.
#
# This request must be SIGNED with your application private key, so it goes
# through Tesla's vehicle-command proxy:
#     docker compose --profile setup up -d vehicle-command
#
# Re-run this whenever you change the field list, and ALSO after your account
# is unblocked from a billing limit -- Tesla DELETES telemetry configurations
# when the limit is exceeded.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "ERROR: .env not found"; exit 1; }
# shellcheck disable=SC1091
set -a; . ./.env; set +a
: "${TESLA_CLIENT_ID:?}"; : "${TESLA_CLIENT_SECRET:?}"
: "${TESLA_API_BASE:?}"; : "${DOMAIN:?}"; : "${VIN:?}"
PROXY_PORT="${PROXY_PORT:-4444}"
TELEMETRY_PORT="${TELEMETRY_PORT:-4443}"
CA=certs/vehicle_device.CA.cert
[ -f "$CA" ] || { echo "ERROR: $CA missing -- run scripts/gen-certs.sh"; exit 1; }

mkdir -p secrets
printf '%s' "$TESLA_CLIENT_SECRET" > secrets/.client_secret
chmod 600 secrets/.client_secret

echo "==> refresh user access token"
[ -f secrets/.refresh_token ] || { echo "ERROR: no refresh token -- run scripts/get-token.sh"; exit 1; }
RESP=$(curl -s -X POST https://auth.tesla.com/oauth2/v3/token \
  --data-urlencode "grant_type=refresh_token" \
  --data-urlencode "client_id=${TESLA_CLIENT_ID}" \
  --data-urlencode "client_secret@secrets/.client_secret" \
  --data-urlencode "refresh_token=$(cat secrets/.refresh_token)")
python3 - "$RESP" <<'PY'
import sys, json
d = json.loads(sys.argv[1])
if d.get("error"):
    print("  ERROR:", d.get("error")); raise SystemExit(1)
open("secrets/.access_token", "w").write(d.get("access_token", ""))
if d.get("refresh_token"):
    open("secrets/.refresh_token", "w").write(d["refresh_token"])
print("  ok")
PY
chmod 600 secrets/.access_token secrets/.refresh_token 2>/dev/null || true
TOKEN=$(cat secrets/.access_token)

echo "==> build config"
python3 - "$CA" "$DOMAIN" "$TELEMETRY_PORT" "$VIN" <<'PY'
import sys, json
ca, domain, port, vin = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
F = {}
def f(name, iv): F[name] = {"interval_seconds": iv}

# Motion. On-change semantics mean a parked car emits almost nothing,
# so short intervals here are cheap and give high drive resolution.
for n in ("Location", "VehicleSpeed", "Gear"): f(n, 2)
f("GpsHeading", 5); f("Odometer", 60)

# Battery + charging
f("Soc", 60); f("BatteryLevel", 60)
for n in ("EstBatteryRange", "IdealBatteryRange", "RatedRange"): f(n, 30)
f("DetailedChargeState", 30); f("ChargeLimitSoc", 300); f("TimeToFullCharge", 60)
for n in ("ACChargingPower", "DCChargingPower"): f(n, 30)
for n in ("ACChargingEnergyIn", "DCChargingEnergyIn", "ChargerVoltage", "ChargeAmps"): f(n, 60)
f("ChargePortDoorOpen", 60)

# Climate
f("InsideTemp", 300); f("OutsideTemp", 300); f("HvacPower", 60)
f("PreconditioningEnabled", 60); f("ClimateKeeperMode", 300)

# Security / body
f("Locked", 60); f("SentryMode", 300); f("DoorState", 60)
for n in ("FdWindow", "FpWindow", "RdWindow", "RpWindow"): f(n, 300)
f("DriverSeatOccupied", 60)

# Diagnostics
for n in ("TpmsPressureFl", "TpmsPressureFr", "TpmsPressureRl", "TpmsPressureRr"): f(n, 3600)
f("Version", 3600)

body = {"vins": [vin], "config": {
    "hostname": domain, "port": port, "ca": open(ca).read(), "fields": F}}
json.dump(body, open("/tmp/nopoll-ftc.json", "w"))
print("  %d fields" % len(F))
PY

echo "==> POST fleet_telemetry_config (signed via vehicle-command proxy)"
curl -s -k "https://127.0.0.1:${PROXY_PORT}/api/1/vehicles/fleet_telemetry_config" \
  -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
  --data @/tmp/nopoll-ftc.json | python3 -c '
import sys, json
d = json.load(sys.stdin)
if d.get("error"):
    print("  ERROR:", d["error"])
    print("  \"hostname domain does not match with partner account\" means the")
    print("  domain is not registered -- run scripts/register-domain.sh first.")
    raise SystemExit(1)
print("  updated_vehicles:", d.get("response", {}).get("updated_vehicles"))
'
rm -f /tmp/nopoll-ftc.json

echo "==> verify (synced flips true once the car picks up the config)"
curl -s "${TESLA_API_BASE}/api/1/vehicles/${VIN}/fleet_telemetry_config" \
  -H "Authorization: Bearer ${TOKEN}" | python3 -c '
import sys, json
r = json.load(sys.stdin).get("response", {}) or {}
c = r.get("config") or {}
print("  synced:", r.get("synced"), "| limit_reached:", r.get("limit_reached"),
      "| key_paired:", r.get("key_paired"))
print("  hostname:", c.get("hostname"), "port:", c.get("port"),
      "fields:", len(c.get("fields") or {}))
'
