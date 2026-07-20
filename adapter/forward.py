import os, base64, json, urllib.request, zmq
ZMQ_ADDR = os.environ.get("ZMQ_ADDR", "tcp://fleet-telemetry:5284")
BRIDGE_URL = os.environ.get("BRIDGE_URL", "http://bridge:8081/")
ctx = zmq.Context()
s = ctx.socket(zmq.SUB)
s.connect(ZMQ_ADDR)
s.setsockopt(zmq.SUBSCRIBE, b"")
print(f"adapter up: {ZMQ_ADDR} -> {BRIDGE_URL}", flush=True)
while True:
    parts = s.recv_multipart()
    payload = parts[-1]
    body = json.dumps({"message": {"data": base64.b64encode(payload).decode()}}).encode()
    try:
        urllib.request.urlopen(urllib.request.Request(BRIDGE_URL, data=body, headers={"Content-Type": "application/json"}), timeout=5)
    except Exception as e:
        print(f"POST failed: {e}", flush=True)
