FROM python:3.12-slim
RUN pip install --no-cache-dir flask flask-sock pyzmq gunicorn
COPY shim.py /app/shim.py
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
WORKDIR /app
# Two listeners: plain :8099 (REST) and TLS :8443 (streaming WebSocket).
# --timeout 0 keeps long-lived stream connections from being reaped.
CMD ["bash", "/app/entrypoint.sh"]
