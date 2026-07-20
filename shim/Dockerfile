FROM python:3.12-slim
RUN pip install --no-cache-dir flask pyzmq gunicorn
COPY shim.py /app/shim.py
WORKDIR /app
CMD ["gunicorn", "-b", "0.0.0.0:8099", "-w", "1", "--threads", "4", "shim:app"]
