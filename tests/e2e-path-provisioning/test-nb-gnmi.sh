#!/bin/bash
# Test direct gNMI Northbound Interface against onos-config

TARGET="localhost:5150"
SERVICE_ID="xc-99"
GNMI_PATH="/quantum-services/cross-connect-service[service-id=${SERVICE_ID}]"
VALUE='{"service-id": "xc-99", "target-node-ip": "10.0.0.5", "ingress-port": 1, "egress-port": 2, "admin-state": "ENABLED"}'

echo "Sending gNMI Set to $TARGET..."
gnmic -a $TARGET --insecure set \
  --update-path "$GNMI_PATH" \
  --update-value "$VALUE"

echo "Verifying gNMI Get..."
gnmic -a $TARGET --insecure get --path "$GNMI_PATH"
