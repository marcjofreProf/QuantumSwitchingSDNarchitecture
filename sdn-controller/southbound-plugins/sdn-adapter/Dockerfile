FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc libxml2-dev libxslt1-dev libffi-dev libssl-dev \
        curl ca-certificates iputils-ping \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# Compile the custom gNOI proto into Python stubs, into /app directly
COPY proto/quantum_gnoi_switching.proto /app/proto/quantum_gnoi_switching.proto
RUN python -m grpc_tools.protoc \
        -I/app/proto \
        --python_out=/app \
        --grpc_python_out=/app \
        /app/proto/quantum_gnoi_switching.proto

COPY adapter.py /app/adapter.py

ENV ADAPTER_PORT=8080 ADAPTER_BIND=0.0.0.0
EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -sf http://localhost:8080/healthz || exit 1

CMD ["python3", "/app/adapter.py"]
