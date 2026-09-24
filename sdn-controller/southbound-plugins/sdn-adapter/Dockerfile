FROM python:3.11-slim

ARG GRPCURL_VERSION=1.9.1

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libxml2-dev \
    libxslt1-dev \
    libffi-dev \
    libssl-dev \
    curl \
    ca-certificates \
    iputils-ping \
    && rm -rf /var/lib/apt/lists/*

# grpcurl — used to invoke arbitrary gNOI/gRPC methods on the device
# via server reflection (no proto files needed at runtime).
RUN ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
      amd64) GRPCURL_ARCH=x86_64 ;; \
      arm64) GRPCURL_ARCH=arm64  ;; \
      *)     GRPCURL_ARCH=x86_64 ;; \
    esac && \
    curl -fsSL -o /tmp/grpcurl.tgz \
      "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_${GRPCURL_ARCH}.tar.gz" && \
    tar -xzf /tmp/grpcurl.tgz -C /usr/local/bin grpcurl && \
    chmod +x /usr/local/bin/grpcurl && \
    rm -f /tmp/grpcurl.tgz

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

WORKDIR /app
COPY adapter.py /app/adapter.py

ENV ADAPTER_PORT=8080 \
    ADAPTER_BIND=0.0.0.0
EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -sf http://localhost:8080/healthz || exit 1

# Real service, not sleep infinity.
CMD ["python3", "/app/adapter.py"]
