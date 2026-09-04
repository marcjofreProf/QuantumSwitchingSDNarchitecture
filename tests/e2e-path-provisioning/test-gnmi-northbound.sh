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
# Ensure Fresh Topology Entity Exists (devicesim-1)
# ------------------------------------------------------------

echo
echo "=== Provisioning Topology Entity 'devicesim-1' ==="

TARGET_ENTITY="devicesim-1"

CLI_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=onos-cli -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
          kubectl get pods -n "$NAMESPACE" -l app=onos-cli -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
          kubectl get pods -n "$NAMESPACE" 2>/dev/null | grep onos-cli | awk '{print $1}' | head -n 1)

if [ -n "$CLI_POD" ]; then
    # Purge existing entity to reset model aspects
    echo "[*] Cleaning up any existing '$TARGET_ENTITY' entity..."
    kubectl exec -n "$NAMESPACE" "$CLI_POD" -- onos topo delete entity "$TARGET_ENTITY" 2>/dev/null || true

    # Create entity matching the loaded plugin (version 1.0.x)
    echo "[*] Creating fresh '$TARGET_ENTITY' entity..."
    kubectl exec -n "$NAMESPACE" "$CLI_POD" -- onos topo create entity "$TARGET_ENTITY" \
        --aspect onos.topo.Configurable='{"type": "devicesim", "version": "1.0.x"}'
else
    echo "[!] ERROR: Unable to locate 'onos-cli' pod in namespace '$NAMESPACE'."
    exit 1
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
# 2. gNMI Set
# ------------------------------------------------------------

echo
echo "=== 2. gNMI Set ==="

gnmic -a "$TARGET" \
    --skip-verify \
    --tls-cert "$TLS_CERT" \
    --tls-key "$TLS_KEY" \
    --target "devicesim-1" \
    set \
    --update "/system/clock/config/timezone-name:::string:::Europe/Paris"


# ------------------------------------------------------------
# 3. gNMI Get
# ------------------------------------------------------------

echo
echo "=== 3. gNMI Get ==="

gnmic -a "$TARGET" \
    --skip-verify \
    --tls-cert "$TLS_CERT" \
    --tls-key "$TLS_KEY" \
    --target "devicesim-1" \
    get \
    --path "/system/clock/config/timezone-name"


# ------------------------------------------------------------
# 4. Result
# ------------------------------------------------------------

echo
echo "=========================================="
echo "[OK] Micro-ONOS gNMI northbound test passed"
echo "=========================================="
