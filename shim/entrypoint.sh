#!/usr/bin/env bash
# Runs two gunicorn listeners for the same app:
#   :8099  plain HTTP   -> TeslaMate's TESLA_API_HOST (REST polling)
#   :8443  TLS          -> TeslaMate's TESLA_WSS_HOST (streaming WebSocket)
#
# gunicorn applies --certfile/--keyfile to every bind, so a single process
# cannot serve one plain and one TLS port. Two processes, same app, is the
# simplest correct answer. If either exits, we bring the whole container down
# so Docker's restart policy replaces it.
set -u

COMMON=(-w 1 --threads 8 --timeout 0 shim:app)

# Each gunicorn needs its own control socket, or the second collides on the
# default path and logs "Address already in use".
gunicorn -b 0.0.0.0:8099 --control-socket /tmp/gunicorn-http.ctl "${COMMON[@]}" &
HTTP_PID=$!

TLS_PID=""
if [ -f /certs/app.cert ] && [ -f /certs/app.key ]; then
  gunicorn -b 0.0.0.0:8443 --control-socket /tmp/gunicorn-tls.ctl \
    --certfile /certs/app.cert --keyfile /certs/app.key "${COMMON[@]}" &
  TLS_PID=$!
else
  echo "[entrypoint] /certs/app.cert not mounted -- TLS/WSS listener (8443) disabled"
fi

term() { kill "$HTTP_PID" $TLS_PID 2>/dev/null; }
trap term SIGTERM SIGINT

# Exit as soon as either listener dies.
wait -n
echo "[entrypoint] a gunicorn listener exited; stopping container for restart"
term
exit 1
