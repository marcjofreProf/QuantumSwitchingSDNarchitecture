#!/bin/bash
#
# Direct gNMI Northbound Interface Test via NodePort
#

set -e

NAMESPACE="micro-onos"
NODE_PORT="30150"
SERVICE_ID="xc-99"

# Dynamically resolve host network IP
HOST_IP=$(hostname -I | awk '{print $1}')
TARGET="${HOST_IP}:${NODE_PORT}"

GNMI_PATH="/quantum-services/cross-connect-service[service-id=${SERVICE_ID}]"

VALUE='{
  "service-id": "xc-99",
  "target-node-ip": "10.0.0.254",
  "ingress-port": 1,
  "egress-port": 2,
  "admin-state": "ENABLED"
}'

# Extract TLS credentials from cluster secret
TLS_DIR="/tmp/onos-config-gnmi"
mkdir -p "$TLS_DIR"

TLS_CERT="$TLS_DIR/tls.crt"
TLS_KEY="$TLS_DIR/tls.key"

echo "[*] Extracting ONOS-config client certificates..."
kubectl get secret onos-config-secret \
  -n "$NAMESPACE" \
  -o jsonpath='{.data.tls\.crt}' |
  base64 -d > "$TLS_CERT"

kubectl get secret onos-config-secret \
  -n "$NAMESPACE" \
  -o jsonpath='{.data.tls\.key}' |
  base64 -d > "$TLS_KEY"

chmod 600 "$TLS_KEY"

cleanup() {
  rm -rf "$TLS_DIR"
}
trap cleanup EXIT INT TERM

echo "[*] gNMI Target: $TARGET"
echo

echo "========================================"
echo " gNMI Capabilities"
echo "========================================"
gnmic -a "$TARGET" \
  --skip-verify \
  --tls-cert "$TLS_CERT" \
  --tls-key "$TLS_KEY" \
  capabilities

echo
echo "========================================"
echo " gNMI Set"
echo "========================================"
echo "[*] Sending gNMI Set to $GNMI_PATH..."
gnmic -a "$TARGET" \
  --skip-verify \
  --tls-cert "$TLS_CERT" \
  --tls-key "$TLS_KEY" \
  --target "$SERVICE_ID" \
  set \
  --replace-path "$GNMI_PATH" \
  --replace-value "$VALUE"

echo
echo "========================================"
echo " gNMI Get"
echo "========================================"
echo "[*] Reading $GNMI_PATH..."
gnmic -a "$TARGET" \
  --skip-verify \
  --tls-cert "$TLS_CERT" \
  --tls-key "$TLS_KEY" \
  --target "$SERVICE_ID" \
  get \
  --path "$GNMI_PATH"

echo
echo "[OK] gNMI Northbound test completed successfully."

