FROM python:3.9-slim

ARG GNMIC_VERSION=0.49.0

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# gnmic CLI — required for the gNMI southbound path in gateway.py.
# Download the release binary directly and assert it runs. The old
# install.sh invocation could silently fail and leave the image without
# gnmic, which only surfaced at runtime as FileNotFoundError.
RUN ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
      amd64) GNMIC_ARCH=x86_64  ;; \
      arm64) GNMIC_ARCH=aarch64 ;; \
      *)     GNMIC_ARCH=x86_64  ;; \
    esac && \
    curl -fsSL -o /tmp/gnmic.tgz \
      "https://github.com/openconfig/gnmic/releases/download/v${GNMIC_VERSION}/gnmic_${GNMIC_VERSION}_linux_${GNMIC_ARCH}.tar.gz" && \
    tar -xzf /tmp/gnmic.tgz -C /usr/local/bin gnmic && \
    chmod +x /usr/local/bin/gnmic && \
    rm -f /tmp/gnmic.tgz && \
    /usr/local/bin/gnmic version

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY gateway.py .

EXPOSE 8181
CMD ["python", "gateway.py"]
