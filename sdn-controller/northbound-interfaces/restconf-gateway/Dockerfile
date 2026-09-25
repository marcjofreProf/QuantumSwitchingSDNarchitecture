FROM python:3.9-slim

ARG GNMI_VERSION=v0.9.1

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

RUN mkdir -p /tmp/proto && \
    curl -fsSL -o /tmp/proto/gnmi.proto \
        "https://raw.githubusercontent.com/openconfig/gnmi/${GNMI_VERSION}/proto/gnmi/gnmi.proto" && \
    curl -fsSL -o /tmp/proto/gnmi_ext.proto \
        "https://raw.githubusercontent.com/openconfig/gnmi/${GNMI_VERSION}/proto/gnmi_ext/gnmi_ext.proto" && \
    sed -i 's|import "github.com/openconfig/gnmi/proto/gnmi_ext/gnmi_ext.proto";|import "gnmi_ext.proto";|' /tmp/proto/gnmi.proto && \
    python -m grpc_tools.protoc \
        -I/tmp/proto \
        --python_out=/app --grpc_python_out=/app \
        /tmp/proto/gnmi.proto /tmp/proto/gnmi_ext.proto && \
    rm -rf /tmp/proto && \
    python -c "import sys; sys.path.insert(0,'/app'); import gnmi_pb2, gnmi_pb2_grpc; print('gNMI stubs OK')"

COPY gateway.py .
EXPOSE 8181
CMD ["python", "gateway.py"]
