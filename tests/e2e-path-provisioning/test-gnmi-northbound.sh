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
# Ensure Topology Entity Exists
# ------------------------------------------------------------

echo
echo "=== Ensuring Topology Entity 'virtual' ==="

if command -v onos >/dev/null 2>&1; then
    if ! onos topo get entity "virtual" >/dev/null 2>&1; then
        echo "[*] Entity 'virtual' not found. Creating..."
        onos topo create entity "virtual" --aspect onos.topo.Configurable='{"type": "devicesim-1.0.x", "version": "1.0.0"}'
    else
        echo "[*] Entity 'virtual' already exists."
    fi
else
    CLI_POD=$(kubectl get pods -n "$NAMESPACE" -l app=onos-cli -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "$CLI_POD" ]; then
        if ! kubectl exec -n "$NAMESPACE" "$CLI_POD" -- onos topo get entity "virtual" >/dev/null 2>&1; then
            echo "[*] Entity 'virtual' not found. Creating via pod..."
            kubectl exec -n "$NAMESPACE" "$CLI_POD" -- onos topo create entity "virtual" --aspect onos.topo.Configurable='{"type": "devicesim-1.0.x", "version": "1.0.0"}'
        else
            echo "[*] Entity 'virtual' already exists."
        fi
    else
        echo "[!] WARNING: 'onos' CLI binary or 'onos-cli' pod not found. Skipping topology entity check."
    fi
fi


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
    --target "devicesim-1" \
    get \
    --path "/"


# ------------------------------------------------------------
# 3. Result
# ------------------------------------------------------------

echo
echo "=========================================="
echo "[OK] Micro-ONOS gNMI northbound test passed"
echo "=========================================="
