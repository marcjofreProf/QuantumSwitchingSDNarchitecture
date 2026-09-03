```bash
#!/bin/bash
#
# Test gNMI Northbound Interface against onos-config
# using kubectl port-forward and mutual TLS.
#

set -e

NAMESPACE="micro-onos"
SERVICE="onos-config"
LOCAL_PORT="5150"
REMOTE_PORT="5150"

SERVICE_ID="xc-99"
GNMI_PATH="/quantum-services/cross-connect-service[service-id=${SERVICE_ID}]"

VALUE='{
  "service-id": "xc-99",
  "target-node-ip": "10.0.0.254",
  "ingress-port": 1,
  "egress-port": 2,
  "admin-state": "ENABLED"
}'

# ----------------------------------------------------------------------
# Temporary TLS files
# ----------------------------------------------------------------------

TLS_DIR="/tmp/onos-config-gnmi"
mkdir -p "$TLS_DIR"

TLS_CERT="$TLS_DIR/tls.crt"
TLS_KEY="$TLS_DIR/tls.key"

echo "[*] Extracting ONOS-config client certificate and key..."

kubectl get secret onos-config-secret \
  -n "$NAMESPACE" \
  -o jsonpath='{.data.tls\.crt}' |
  base64 -d > "$TLS_CERT"

kubectl get secret onos-config-secret \
  -n "$NAMESPACE" \
  -o jsonpath='{.data.tls\.key}' |
  base64 -d > "$TLS_KEY"

chmod 600 "$TLS_KEY"

# ----------------------------------------------------------------------
# Check that the ONOS-config service exists
# ----------------------------------------------------------------------

if ! kubectl get svc "$SERVICE" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "[ERROR] Kubernetes service '$SERVICE' not found in namespace '$NAMESPACE'."
  exit 1
fi

# ----------------------------------------------------------------------
# Start port-forward
# ----------------------------------------------------------------------

echo "[*] Starting port-forward:"
echo "    localhost:${LOCAL_PORT} -> ${SERVICE}:${REMOTE_PORT}"

kubectl port-forward \
  -n "$NAMESPACE" \
  "svc/${SERVICE}" \
  "${LOCAL_PORT}:${REMOTE_PORT}" \
  >/tmp/onos-config-port-forward.log 2>&1 &

PF_PID=$!

cleanup()
{
  echo
  echo "[*] Cleaning up..."

  if kill "$PF_PID" 2>/dev/null; then
    wait "$PF_PID" 2>/dev/null || true
  fi

  rm -rf "$TLS_DIR"
}

trap cleanup EXIT INT TERM

# ----------------------------------------------------------------------
# Wait for port-forward to become available
# ----------------------------------------------------------------------

echo "[*] Waiting for port-forward..."

for i in {1..20}; do
  if (echo >/dev/tcp/127.0.0.1/$LOCAL_PORT) \
      >/dev/null 2>&1; then
    break
  fi

  if ! kill -0 "$PF_PID" 2>/dev/null; then
    echo "[ERROR] kubectl port-forward terminated."
    cat /tmp/onos-config-port-forward.log
    exit 1
  fi

  sleep 0.5
done

if ! (echo >/dev/tcp/127.0.0.1/$LOCAL_PORT) \
    >/dev/null 2>&1; then
  echo "[ERROR] Could not connect to localhost:${LOCAL_PORT}."
  cat /tmp/onos-config-port-forward.log
  exit 1
fi

TARGET="localhost:${LOCAL_PORT}"

echo "[*] Target: $TARGET"
echo

# ----------------------------------------------------------------------
# Test gNMI Capabilities
# ----------------------------------------------------------------------

echo "========================================"
echo " gNMI Capabilities"
echo "========================================"

gnmic \
  -a "$TARGET" \
  --skip-verify \
  --tls-cert "$TLS_CERT" \
  --tls-key "$TLS_KEY" \
  capabilities

echo

# ----------------------------------------------------------------------
# gNMI Set
# ----------------------------------------------------------------------

echo "========================================"
echo " gNMI Set"
echo "========================================"

echo "[*] Sending gNMI Set to:"
echo "    $GNMI_PATH"
echo

gnmic \
  -a "$TARGET" \
  --skip-verify \
  --tls-cert "$TLS_CERT" \
  --tls-key "$TLS_KEY" \
  set \
  --update-path "$GNMI_PATH" \
  --update-value "$VALUE"

echo

# ----------------------------------------------------------------------
# gNMI Get
# ----------------------------------------------------------------------

echo "========================================"
echo " gNMI Get"
echo "========================================"

echo "[*] Reading:"
echo "    $GNMI_PATH"
echo

gnmic \
  -a "$TARGET" \
  --skip-verify \
  --tls-cert "$TLS_CERT" \
  --tls-key "$TLS_KEY" \
  get \
  --path "$GNMI_PATH"

echo
echo "[OK] gNMI Northbound test completed successfully."
```
