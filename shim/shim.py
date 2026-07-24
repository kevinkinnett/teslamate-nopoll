"""Tesla Fleet API shim.

Impersonates the subset of the Fleet API that TeslaMate polls, serving a full
vehicle_data document that is SEEDED from one real API response and then kept
live by patching it from the Fleet Telemetry stream (ZMQ).

Units: telemetry values match the real API 1:1 (ranges in miles, temps in C,
odometer in miles) -- verified empirically. NO conversion is applied.
"""
import copy
import json
import os
import threading
import time

import zmq
from flask import Flask, jsonify
from flask_sock import Sock

VIN        = os.environ.get("VIN", "")
NAME       = os.environ.get("DISPLAY_NAME", "Tesla")
ZMQ_ADDR   = os.environ.get("ZMQ_ADDR", "tcp://fleet-telemetry:5284")
ASLEEP_SEC = int(os.environ.get("ASLEEP_AFTER_SEC", "1200"))
DATA_DIR   = os.environ.get("DATA_DIR", "/data")
SEED_FILE  = os.path.join(DATA_DIR, "seed.json")
STATE_FILE = os.path.join(DATA_DIR, "state.json")

LOCK = threading.Lock()
DOC = None          # full vehicle_data "response" document
LAST_SIGNAL = 0.0   # epoch of last telemetry message
RAW = {}            # last raw telemetry value per key (for /debug)
app = Flask(__name__)
# Keepalive pings. The stream handler blocks sending updates rather than
# calling receive() in a loop, so server-side pings are what detect a peer
# that has gone away. Note TeslaMate cycles the stream on its own schedule
# (connect, hold for minutes, disconnect, reconnect) -- that is normal and
# not something to debug.
app.config["SOCK_SERVER_OPTIONS"] = {"ping_interval": 25}
sock = Sock(app)


# ---------- helpers ----------

def unwrap(v):
    """Telemetry values are type-wrapped: {"doubleValue": 1.2}."""
    if not isinstance(v, dict):
        return v
    if "invalid" in v:
        return None
    if "locationValue" in v:
        return v["locationValue"]
    for k in ("doubleValue", "floatValue", "intValue", "longValue",
              "stringValue", "booleanValue", "boolValue"):
        if k in v:
            return v[k]
    for k, val in v.items():
        if k.endswith("Value"):
            return val
    return v


def enum_tail(v):
    """Telemetry enums arrive as '<Field>State<Value>' strings, e.g.
    'SentryModeStateArmed', 'WindowStateClosed', 'ShiftStateP'. Return just the
    trailing value ('Armed', 'Closed', 'P'). Plain values pass through."""
    if v is None:
        return ""
    s = str(v)
    i = s.rfind("State")
    return s[i + 5:] if i >= 0 else s


# Enum tails (and plain strings) that mean "yes/on".
_TRUE_WORDS = {"true", "1", "on", "yes", "vent", "enabled", "armed", "active"}


def truthy(v):
    """Boolean-ish conversion that understands telemetry enum strings.

    Without enum awareness every '<Field>State<Value>' string falls through to
    False, which silently reports windows closed and climate off no matter what
    the car is actually doing.

    Window/door states are matched by prefix rather than exact word: Tesla sends
    'Opened' (past tense) and variants like 'PartiallyOpen', so an exact-match
    list quietly reports an open window as closed.
    """
    if isinstance(v, bool):
        return v
    if v is None:
        return False
    t = enum_tail(v).strip().lower()
    if t in _TRUE_WORDS:
        return True
    return t.startswith("open") or "partial" in t


def sentry_on(v):
    """Tesla exposes sentry as a boolean, but telemetry sends a state enum:
    Off / Idle / Armed / Aware / Panic / Quiet. Everything except Off (and
    unknown) means the feature is enabled."""
    if isinstance(v, bool):
        return v
    return enum_tail(v).strip().lower() not in ("", "off", "unknown")


def as_shift(v):
    s = enum_tail(v).strip()
    if not s:
        return None
    c = s[:1].upper()
    return c if c in ("P", "D", "R", "N") else None


def window(v):
    return 1 if truthy(v) else 0


# DoorState is delivered as a single dict; map its members onto the flat
# per-door fields the Fleet API (and TeslaMate) expect.
DOOR_MAP = {
    "DriverFront": "df", "DriverRear": "dr",
    "PassengerFront": "pf", "PassengerRear": "pr",
    "TrunkFront": "ft", "TrunkRear": "rt",
}


def to_int(v):
    """TeslaMate validates several fields as integers; telemetry sends floats."""
    try:
        return int(round(float(v)))
    except (TypeError, ValueError):
        return None


# telemetry key -> (section, field, transform)
MAP = {
    "Soc":                  [("charge_state", "battery_level", to_int),
                             ("charge_state", "usable_battery_level", to_int)],
    "BatteryLevel":         [("charge_state", "battery_level", to_int)],
    "RatedRange":           [("charge_state", "battery_range", None)],
    "IdealBatteryRange":    [("charge_state", "ideal_battery_range", None)],
    "EstBatteryRange":      [("charge_state", "est_battery_range", None)],
    "ChargeLimitSoc":       [("charge_state", "charge_limit_soc", to_int)],
    "TimeToFullCharge":     [("charge_state", "time_to_full_charge", None)],
    "ChargerVoltage":       [("charge_state", "charger_voltage", to_int)],
    "ChargeAmps":           [("charge_state", "charger_actual_current", to_int),
                             ("charge_state", "charge_current_request", to_int)],
    "DCChargingEnergyIn":   [("charge_state", "charge_energy_added", None)],
    "ChargePortDoorOpen":   [("charge_state", "charge_port_door_open", truthy)],
    "DetailedChargeState":  [("charge_state", "charging_state",
                              lambda v: enum_tail(v).strip() or "Disconnected")],

    "GpsHeading":           [("drive_state", "heading", to_int)],
    "VehicleSpeed":         [("drive_state", "speed", to_int)],
    "Gear":                 [("drive_state", "shift_state", as_shift)],

    "Odometer":             [("vehicle_state", "odometer", None)],
    "Locked":               [("vehicle_state", "locked", truthy)],
    "SentryMode":           [("vehicle_state", "sentry_mode", sentry_on)],
    "DriverSeatOccupied":   [("vehicle_state", "is_user_present", truthy)],
    "Version":              [("vehicle_state", "car_version", None)],
    "FdWindow":             [("vehicle_state", "fd_window", window)],
    "FpWindow":             [("vehicle_state", "fp_window", window)],
    "RdWindow":             [("vehicle_state", "rd_window", window)],
    "RpWindow":             [("vehicle_state", "rp_window", window)],
    "TpmsPressureFl":       [("vehicle_state", "tpms_pressure_fl", None)],
    "TpmsPressureFr":       [("vehicle_state", "tpms_pressure_fr", None)],
    "TpmsPressureRl":       [("vehicle_state", "tpms_pressure_rl", None)],
    "TpmsPressureRr":       [("vehicle_state", "tpms_pressure_rr", None)],

    "InsideTemp":           [("climate_state", "inside_temp", None)],
    "OutsideTemp":          [("climate_state", "outside_temp", None)],
    "HvacPower":            [("climate_state", "is_climate_on", truthy)],
    "PreconditioningEnabled": [("climate_state", "is_preconditioning", truthy)],
    "ClimateKeeperMode":    [("climate_state", "climate_keeper_mode",
                              lambda v: (enum_tail(v).strip() or "off").lower())],
}


def blank_doc():
    return {
        "id": 0, "user_id": 0, "vehicle_id": 0, "vin": VIN,
        "display_name": "Tesla", "state": "asleep",
        "in_service": False, "calendar_enabled": True, "api_version": 71,
        "charge_state": {}, "climate_state": {}, "drive_state": {},
        "vehicle_state": {}, "vehicle_config": {}, "gui_settings": {},
    }


def load_state():
    """Return (doc, raw).

    Accepts the current {"doc":…, "raw":…} format, the older bare-document
    format, and a seed captured straight from the Fleet API.
    """
    for path in (STATE_FILE, SEED_FILE):
        try:
            with open(path) as fh:
                data = json.load(fh)
        except Exception:
            continue
        if isinstance(data, dict) and "doc" in data:
            print("[shim] loaded %s (doc+raw)" % path, flush=True)
            return (data.get("doc") or blank_doc()), (data.get("raw") or {})
        doc = data.get("response", data) if isinstance(data, dict) else None
        if isinstance(doc, dict) and doc.get("charge_state") is not None:
            print("[shim] loaded %s" % path, flush=True)
            return doc, {}
    print("[shim] no seed found; starting blank", flush=True)
    return blank_doc(), {}


def persist():
    """Persist the derived document AND the raw signals it came from.

    The temp file is per-process: entrypoint.sh runs two gunicorn listeners
    (plain and TLS) and each has its own subscriber, so a shared temp name made
    them race -- one would os.replace() the file the other was about to move,
    and that process's save failed with ENOENT. Both still write the same final
    path; last writer wins, which is fine because both derive from the same
    telemetry feed.
    """
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        tmp = "%s.%d.tmp" % (STATE_FILE, os.getpid())
        with open(tmp, "w") as fh:
            json.dump({"doc": DOC, "raw": RAW}, fh)
        os.replace(tmp, STATE_FILE)
    except Exception as exc:
        print("[shim] persist failed: %s" % exc, flush=True)


def apply_signal(key, value):
    targets = MAP.get(key)
    if not targets:
        return
    for section, field, fn in targets:
        try:
            DOC.setdefault(section, {})[field] = fn(value) if fn else value
        except Exception:
            pass


def apply_composites():
    """Signals that arrive as one value but populate several document fields."""
    loc = RAW.get("Location")
    if isinstance(loc, dict):
        lat, lon = loc.get("latitude"), loc.get("longitude")
        ds = DOC.setdefault("drive_state", {})
        ds["latitude"] = ds["native_latitude"] = lat
        ds["longitude"] = ds["native_longitude"] = lon
    # charger_power: AC and DC are separate signals; take whichever is live.
    ac, dc = RAW.get("ACChargingPower"), RAW.get("DCChargingPower")
    vals = [x for x in (ac, dc) if isinstance(x, (int, float))]
    if vals:
        DOC.setdefault("charge_state", {})["charger_power"] = to_int(max(vals))
    # DoorState arrives as one dict covering every door.
    doors = RAW.get("DoorState")
    if isinstance(doors, dict):
        vs = DOC.setdefault("vehicle_state", {})
        for src, dst in DOOR_MAP.items():
            if src in doors:
                vs[dst] = 1 if truthy(doors[src]) else 0


def reapply_all():
    """Re-derive the whole document from the raw signals we have on hand.

    Run at startup. Telemetry is delta-only, so without this a change to the
    mapping logic would only take effect when each field next happens to
    change -- a slow signal like SentryMode could stay wrong for days.
    """
    for k, v in RAW.items():
        if v is not None:
            apply_signal(k, v)
    apply_composites()
    if RAW:
        print("[shim] re-derived document from %d stored signals" % len(RAW), flush=True)


def zmq_loop():
    global LAST_SIGNAL
    ctx = zmq.Context()
    sock = ctx.socket(zmq.SUB)
    sock.connect(ZMQ_ADDR)
    sock.setsockopt_string(zmq.SUBSCRIBE, "")
    print("[shim] subscribed to %s" % ZMQ_ADDR, flush=True)
    last_save = 0.0
    while True:
        try:
            parts = sock.recv_multipart()
            msg = json.loads(parts[-1].decode("utf-8", "ignore"))
        except Exception:
            continue
        if not isinstance(msg, dict) or not msg.get("data"):
            continue
        now = time.time()
        with LOCK:
            for item in msg["data"]:
                key = item.get("key")
                if not key:
                    continue
                val = unwrap(item.get("value"))
                RAW[key] = val
                if val is not None:
                    apply_signal(key, val)
            apply_composites()
            LAST_SIGNAL = now
            if now - last_save > 30:
                persist()
                last_save = now


def online():
    return (time.time() - LAST_SIGNAL) < ASLEEP_SEC


def snapshot():
    ts = int(time.time() * 1000)
    with LOCK:
        doc = copy.deepcopy(DOC)
    doc["state"] = "online" if online() else "asleep"
    for section in ("charge_state", "climate_state", "drive_state",
                    "vehicle_state", "vehicle_config", "gui_settings"):
        if isinstance(doc.get(section), dict):
            doc[section]["timestamp"] = ts
    doc.setdefault("drive_state", {})["gps_as_of"] = int(LAST_SIGNAL)
    return doc


def summary():
    doc = snapshot()
    out = {k: doc.get(k) for k in
           ("id", "user_id", "vehicle_id", "vin", "display_name", "state",
            "in_service", "calendar_enabled", "api_version")}
    if not out.get("display_name"):
        out["display_name"] = NAME
    return out


# ---------- routes ----------

@app.route("/api/1/vehicles")
def r_vehicles():
    return jsonify({"response": [summary()], "count": 1})


@app.route("/api/1/vehicles/<vid>")
def r_vehicle(vid):
    return jsonify({"response": summary()})


@app.route("/api/1/vehicles/<vid>/vehicle_data")
def r_vehicle_data(vid):
    if not online():
        return jsonify({"response": None,
                        "error": "vehicle unavailable: vehicle is offline or asleep"}), 408
    return jsonify({"response": snapshot()})


@app.route("/api/1/vehicles/<vid>/wake_up", methods=["POST"])
def r_wake(vid):
    return jsonify({"response": summary()})


@app.route("/api/1/products")
def r_products():
    """TeslaMate polls this for energy products (Powerwall/solar). We have none."""
    return jsonify({"response": [], "count": 0})


@app.route("/debug")
def r_debug():
    age = time.time() - LAST_SIGNAL if LAST_SIGNAL else None
    with LOCK:
        raw = dict(RAW)
    return jsonify({
        "online": online(),
        "seconds_since_signal": round(age, 1) if age is not None else None,
        "telemetry_keys_seen": sorted(raw),
        "raw": raw,
        "vehicle_data": snapshot(),
    })


# ---------------------------------------------------------------------------
# TeslaMate streaming endpoint (TESLA_WSS_HOST)
#
# Reimplements the legacy Tesla streaming protocol that TeslaMate still speaks,
# so we can serve it directly from the telemetry stream. TeslaMate sends a
# `data:subscribe_oauth` frame and then expects `data:update` frames whose
# `value` is a comma-separated row in this exact column order:
#
#   timestamp_ms, speed, odometer, soc, elevation, est_heading, est_lat,
#   est_lng, power, shift_state, range, est_range, heading
#
# Missing values are sent empty; TeslaMate reads them as nil. Written from the
# wire format, not from any existing bridge implementation.
# ---------------------------------------------------------------------------

STREAM_COLUMNS = ("speed", "odometer", "soc", "elevation", "est_heading",
                  "est_lat", "est_lng", "power", "shift_state", "range",
                  "est_range", "heading")


def stream_row():
    doc = snapshot()
    cs = doc.get("charge_state", {}) or {}
    ds = doc.get("drive_state", {}) or {}
    vs = doc.get("vehicle_state", {}) or {}
    values = {
        "speed": ds.get("speed"),
        "odometer": vs.get("odometer"),
        "soc": cs.get("battery_level"),
        "elevation": None,                      # not available via telemetry
        "est_heading": ds.get("heading"),
        "est_lat": ds.get("latitude"),
        "est_lng": ds.get("longitude"),
        "power": ds.get("power"),
        "shift_state": ds.get("shift_state"),
        "range": cs.get("battery_range"),
        "est_range": cs.get("est_battery_range"),
        "heading": ds.get("heading"),
    }
    cells = [str(int(time.time() * 1000))]
    for col in STREAM_COLUMNS:
        v = values.get(col)
        cells.append("" if v is None else str(v))
    return ",".join(cells)


def r_streaming(ws):
    tag = VIN
    try:
        first = ws.receive(timeout=30)
    except Exception:
        return
    if first:
        try:
            msg = json.loads(first)
            tag = msg.get("tag") or tag
            print("[shim] stream subscribe: %s tag=%s"
                  % (msg.get("msg_type"), tag), flush=True)
        except Exception:
            pass

    sent_at = 0.0
    try:
        while True:
            if LAST_SIGNAL > sent_at:
                sent_at = LAST_SIGNAL
                ws.send(json.dumps({"msg_type": "data:update",
                                    "tag": str(tag),
                                    "value": stream_row()}))
            time.sleep(1)
    except Exception:
        pass
    finally:
        print("[shim] stream closed tag=%s" % tag, flush=True)


# NOTE: two flask_sock gotchas:
#  1. its route decorator does not return the wrapped function, so decorators
#     cannot be stacked;
#  2. Flask derives the endpoint name from __name__, so registering the same
#     function on two paths collides ("overwriting an existing endpoint").
# Register each path via a thin uniquely-named wrapper.
def _register_stream(path, endpoint_name):
    def handler(ws):
        return r_streaming(ws)
    handler.__name__ = endpoint_name
    sock.route(path)(handler)


_register_stream("/streaming/", "streaming_slash")
_register_stream("/streaming", "streaming_noslash")


UNHANDLED = {}


@app.route("/", defaults={"path": ""})
@app.route("/<path:path>", methods=["GET", "POST", "PUT", "DELETE"])
def r_catchall(path):
    """Log anything TeslaMate asks for that we haven't implemented."""
    key = "/" + path
    UNHANDLED[key] = UNHANDLED.get(key, 0) + 1
    print("[shim] UNHANDLED %s (x%d)" % (key, UNHANDLED[key]), flush=True)
    return jsonify({"response": {}, "error": None}), 200


@app.route("/unhandled")
def r_unhandled():
    return jsonify(UNHANDLED)


DOC, RAW = load_state()
reapply_all()

# Tests import this module for its pure helpers; SHIM_NO_START=1 skips the
# background subscriber so importing does not open sockets or spawn threads.
if os.environ.get("SHIM_NO_START") != "1":
    threading.Thread(target=zmq_loop, daemon=True).start()
