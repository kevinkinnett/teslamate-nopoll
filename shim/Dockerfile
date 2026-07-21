FROM python:3.12-slim
RUN pip install --no-cache-dir flask flask-sock pyzmq gunicorn
COPY shim.py /app/shim.py
WORKDIR /app
# gthread worker: each WebSocket connection holds a thread for its lifetime,
# so leave headroom beyond the single TeslaMate stream client.
# --timeout 0 prevents gunicorn from reaping long-lived stream connections.
CMD ["gunicorn", "-b", "0.0.0.0:8099", "-w", "1", "--threads", "8", "--timeout", "0", "shim:app"]
