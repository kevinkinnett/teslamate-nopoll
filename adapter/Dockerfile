FROM python:3.12-slim
RUN pip install --no-cache-dir pyzmq requests
COPY forward.py /forward.py
CMD ["python", "-u", "/forward.py"]
