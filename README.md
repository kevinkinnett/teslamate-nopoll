# teslamate-nopoll

**Run TeslaMate on Tesla Fleet Telemetry — fully self-hosted, with no per-request API bill.**

> *Not affiliated with or endorsed by Tesla, Inc. or the TeslaMate project.*

**teslamate-nopoll** is a small service that impersonates the Tesla Fleet API for
[TeslaMate](https://github.com/teslamate-org/teslamate). Your car streams telemetry
directly to *your* server; nopoll turns that stream into the `vehicle_data` responses
TeslaMate expects. TeslaMate never talks to Tesla's paid API, and your driving and
location history never leaves your infrastructure.

> **Status:** working, early. Built and validated against a 2026 Model Y.

---

## Why this exists

Tesla's Fleet API bills **$0.002 per `vehicle_data` request**, against a $10/month credit.
That sounds generous until you notice how TeslaMate actually behaves:

**TeslaMate polls `vehicle_data` roughly once a minute for as long as the car is awake.**

If your car sleeps reliably, you'll stay inside the free credit. But if you run
**Sentry Mode** — as you must if you park on a street or in a shared garage — the car
*never sleeps*. It also slowly drains and repeatedly tops up, which keeps TeslaMate
polling around the clock:

```
~1,460 requests/day  ->  ~$2.90/day  ->  ~$88/month
```

**Fleet Telemetry alone does not fix this.** Telemetry gives TeslaMate richer *drive*
data, but TeslaMate still polls the REST API for vehicle *state* (charge, climate,
locks). There is no TeslaMate setting to poll less when the car cannot sleep.

nopoll closes that gap: it answers those polls locally, from the telemetry stream.

---

## How it works

```
                    mTLS WebSocket (:4443)
   Your Tesla  ─────────────────────────────►  fleet-telemetry
                                                     │ ZMQ
                                                     ▼
                                                   nopoll
                                                     │
                          vehicle_data REST (:8099)  │
   TeslaMate  ◄──────────────────────────────────────┘
```

nopoll keeps an in-memory `vehicle_data` document:

1. **Seeded once** from a single real Fleet API call (~$0.002).
2. **Patched continuously** from the telemetry stream as signals arrive.
3. **Served** to TeslaMate on every poll — locally, free, unlimited.

Seeding matters because **telemetry is delta-only**: the car sends a field only when it
*changes*. A cold service would never learn slow-moving values like `charge_limit_soc`,
`sentry_mode`, `car_version`, or the odometer of a parked car.

### Cost after switching

| | Before | After |
|---|---|---|
| Parked, Sentry on | ~1,460 req/day (~$88/mo) | **0** |
| Per drive | ~830 req | **0** |
| Streaming signals | — | ~$0.01/mo |
| Service restart (re-seed) | — | ~$0.002 |

---

## What you need

- A Tesla that supports Fleet Telemetry (2021+; firmware 2024.26 or newer)
- A **Tesla developer app** with a registered partner domain
- A **public hostname** resolving to your network, and the ability to port-forward
- Docker + Docker Compose
- An existing TeslaMate install

---

## Quick start

```bash
git clone https://github.com/<you>/teslamate-nopoll.git && cd teslamate-nopoll
cp .env.example .env      # fill in VIN, domain, client id/secret
./scripts/gen-certs.sh    # self-signed CA + server cert for the car's mTLS
docker compose up -d
```

Then complete the Tesla-side registration (see below) and point TeslaMate at nopoll:

```env
TESLA_API_HOST=http://<nopoll-host>:8099
# leave TESLA_AUTH_HOST alone — auth is free and must stay real
```

Recreate TeslaMate so it picks up the change (`docker compose up -d`, not `restart`).

---

## The Tesla-side setup gauntlet

This is the part that is poorly documented and where most of the pain lives.
Tesla enforces a chain of requirements, and each error message points at only one link:

```
fleet_telemetry_config hostname
        must be a registered PARTNER DOMAIN
                must be listed as an ALLOWED ORIGIN on your app
                        which Tesla validates by fetching
                        https://<domain>/.well-known/appspecific/com.tesla.3p.public-key.pem
                        over HTTPS/443 with a publicly trusted certificate
```

Practical consequences:

- **You need TWO certificates.** A long-lived **self-signed** cert for the car's mTLS
  stream on `:4443` (the car validates it against the CA you register), *and* a real
  **Let's Encrypt** cert on `:443` to serve the public key. These are unrelated; the
  common advice that "no Let's Encrypt is needed" applies only to the mTLS endpoint.
- **Order matters.** Tesla validates the domain *as you type it* into Allowed Origins,
  so the `:443` endpoint must already be live and serving a valid cert.
- nopoll ships a Caddy service that obtains the LE cert and serves the key for you.

### Router notes

- Forward **443** and **80** (cert issuance/renewal) plus your telemetry port (**4443**).
- **AT&T gateways reserve port 443.** The built-in `ssl` "Hosted Application" preset
  silently fails (connection reset); creating a **custom** NAT/Gaming service entry for
  TCP 443 works. Other ISPs' routers have similar quirks — test from outside your LAN.

---

## Gotchas worth knowing

These cost real debugging time. All are handled by nopoll, but if you fork or extend it:

| Gotcha | Detail |
|---|---|
| **No unit conversion** | Telemetry matches the REST API 1:1 — ranges and odometer in **miles**, temps in **Celsius**. Converting km→mi shows 169 mi where the real answer is 273. |
| **TeslaMate validates integers** | `battery_level`, `charge_limit_soc`, `charger_power`, `charger_voltage`, `charger_actual_current` must be ints. Telemetry sends `16.00000023841858`; TeslaMate silently drops the record. |
| **Location is opt-in** | `vehicle_data` omits lat/lon unless you request `?endpoints=location_data;...`. A parked car never streams `Location`, so it must come from the seed. |
| **Delta-only stream** | Seed from a real call or slow-moving fields stay null forever. |
| **Sentry keeps the car awake** | This is the whole reason nopoll exists. If your car sleeps reliably, you may not need it. |

---

## Security

nopoll serves an **unauthenticated** API containing your vehicle's location. Bind it to a
private interface (loopback, a VPN address such as Tailscale, or an internal Docker
network) — **never** expose port 8099 to the internet.

**Never commit:** `.env`, OAuth tokens, your app's private key, the CA key, or
`data/seed.json` — the seed contains your **VIN, home coordinates, and odometer**.
The included `.gitignore` covers these.

---

## Alternatives

- **[MyTeslaMate](https://www.myteslamate.com/)** offers this as a hosted service with a
  free tier, and is considerably easier to set up. The tradeoff is that your vehicle data
  flows through a third party. Choose nopoll if you specifically want everything
  self-hosted; choose MyTeslaMate if you want it working in ten minutes.
- **Owner API** is deprecated and no longer an option for new setups.

---

## Roadmap

- **Fold the streaming bridge into the shim.** Today the TeslaMate streaming
  path runs through `adapter` + `bridge` + a TLS front (`wss`), where `bridge`
  is a third-party image expecting a Google Pub/Sub push envelope. The shim can
  serve that WebSocket itself, collapsing four services into two and removing
  the last external dependency.
- Optional Prometheus metrics for stream health and field freshness.

## Limitations

- `power`, `elevation`, and `active_route_*` (navigation destination/ETA) are not
  available via telemetry and will read null.
- `charge_energy_added` is derived from `DCChargingEnergyIn`; this needs validation
  across a full AC charging session.
- Tesla **deletes your telemetry configuration** if you exceed your billing limit —
  re-run `scripts/register-telemetry.sh` after raising it.

---

## License

MIT
