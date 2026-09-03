#!/bin/bash
set -e

NAMESPACE="micro-onos"
NODE_PORT="30150"
TARGET_DEVICE="devicesim-1"
SERVICE_ID="xc-99"

HOST_IP=$(hostname -I | awk '{print $1}')
TARGET="${HOST_IP}:${NODE_PORT}"

GNMI_PARENT_PATH="/quantum-services"
GNMI_SERVICE_PATH="/quantum-services/cross-connect-service[service-id=${SERVICE_ID}]"

VALUE='{
  "cross-connect-service": [
    {
      "service-id": "xc-99",
      "target-node-ip": "10.0.0.254",
      "ingress-port": 1,
      "egress-port": 2,
      "admin-state": "ENABLED"
    }
  ]
}'

TLS_DIR="/tmp/onos-config-gnmi"
mkdir -p "$TLS_DIR"
TLS_CERT="$TLS_DIR/tls.crt"
TLS_KEY="$TLS_DIR/tls.key"

kubectl get secret onos-config-secret -n "$NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$TLS_CERT"
kubectl get secret onos-config-secret -n "$NAMESPACE" -o jsonpath='{.data.tls\.key}' | base64 -d > "$TLS_KEY"
chmod 600 "$TLS_KEY"

cleanup() { rm -rf "$TLS_DIR"; }
trap cleanup EXIT INT TERM

echo "[*] gNMI Target: $TARGET (Device: $TARGET_DEVICE)"

echo "=== gNMI Capabilities ==="
gnmic -a "$TARGET" --skip-verify --tls-cert "$TLS_CERT" --tls-key "$TLS_KEY" capabilities

echo "=== gNMI Set (Create Service) ==="
gnmic -a "$TARGET" \
  --skip-verify \
  --tls-cert "$TLS_CERT" \
  --tls-key "$TLS_KEY" \
  --target "$TARGET_DEVICE" \
  set \
  --update-path "$GNMI_PARENT_PATH" \
  --update-value "$VALUE"

echo "=== gNMI Get (Verify Service) ==="
gnmic -a "$TARGET" \
  --skip-verify \
  --tls-cert "$TLS_CERT" \
  --tls-key "$TLS_KEY" \
  --target "$TARGET_DEVICE" \
  get \
  --path "$GNMI_SERVICE_PATH"

echo "[OK] gNMI test passed."

