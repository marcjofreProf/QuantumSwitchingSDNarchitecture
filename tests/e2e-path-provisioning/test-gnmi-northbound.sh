#!/bin/bash
# Test direct gNMI Northbound Interface against onos-config via K8s ClusterIP

# --- ROUTE CHECK & INJECTION ---
if ! ip route | grep -q "10.43.0.0/16"; then
  echo "[*] K3s ClusterIP route missing. Injecting 10.43.0.0/16 via cni0..."
  sudo ip route add 10.43.0.0/16 dev cni0 2>/dev/null || true
fi

# Dynamically discover onos-config ClusterIP in micro-onos namespace
CLUSTER_IP=$(kubectl get svc onos-config -n micro-onos -o jsonpath='{.spec.clusterIP}' 2>/dev/null)

if [ -z "$CLUSTER_IP" ]; then
  echo "[ERROR] Could not resolve ClusterIP for 'onos-config' in namespace 'micro-onos'."
  exit 1
fi

TARGET="${CLUSTER_IP}:5150"
SERVICE_ID="xc-99"
GNMI_PATH="/quantum-services/cross-connect-service[service-id=${SERVICE_ID}]"
VALUE='{"service-id": "xc-99", "target-node-ip": "10.0.0.5", "ingress-port": 1, "egress-port": 2, "admin-state": "ENABLED"}'

echo "[*] Target resolved to ClusterIP: $TARGET"

echo "Sending gNMI Set to $TARGET..."
gnmic -a $TARGET --insecure set \
  --update-path "$GNMI_PATH" \
  --update-value "$VALUE"

echo "Verifying gNMI Get..."
gnmic -a $TARGET --insecure get --path "$GNMI_PATH"
