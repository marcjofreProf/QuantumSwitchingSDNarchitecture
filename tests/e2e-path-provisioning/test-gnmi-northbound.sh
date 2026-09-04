#!/bin/bash
set -e

NAMESPACE="micro-onos"
NODE_PORT="30150"

HOST_IP=$(hostname -I | awk '{print $1}')
TARGET="${HOST_IP}:${NODE_PORT}"

TLS_DIR="/tmp/onos-config-gnmi"
mkdir -p "$TLS_DIR"

TLS_CERT="$TLS_DIR/tls.crt"
TLS_KEY="$TLS_DIR/tls.key"

echo "=========================================="
echo " Micro-ONOS gNMI Northbound Test"
echo "=========================================="
echo
echo "[*] Namespace : $NAMESPACE"
echo "[*] Target    : $TARGET"
echo

# ------------------------------------------------------------
# Obtain TLS credentials
# ------------------------------------------------------------

echo "=== Getting TLS credentials ==="

kubectl get secret onos-config-secret \
    -n "$NAMESPACE" \
    -o jsonpath='{.data.tls\.crt}' |
    base64 -d > "$TLS_CERT"

kubectl get secret onos-config-secret \
    -n "$NAMESPACE" \
    -o jsonpath='{.data.tls\.key}' |
    base64 -d > "$TLS_KEY"

chmod 600 "$TLS_KEY"

cleanup()
{
    rm -rf "$TLS_DIR"
}

trap cleanup EXIT INT TERM


# ------------------------------------------------------------
# 1. gNMI Capabilities
# ------------------------------------------------------------

echo
echo "=== 1. gNMI Capabilities ==="

gnmic -a "$TARGET" \
    --skip-verify \
    --tls-cert "$TLS_CERT" \
    --tls-key "$TLS_KEY" \
    capabilities


# ------------------------------------------------------------
# 2. gNMI Get
# ------------------------------------------------------------

echo
echo "=== 2. gNMI Get ==="

gnmic -a "$TARGET" \
    --skip-verify \
    --tls-cert "$TLS_CERT" \
    --tls-key "$TLS_KEY" \
    get \
    --path "/"


# ------------------------------------------------------------
# 3. Result
# ------------------------------------------------------------

echo
echo "=========================================="
echo "[OK] Micro-ONOS gNMI northbound test passed"
echo "=========================================="

