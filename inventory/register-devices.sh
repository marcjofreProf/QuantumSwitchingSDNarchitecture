#!/usr/bin/env bash
# inventory/register-devices.sh

set -eo pipefail

DEVICES_DIR="$(dirname "$0")/devices"
NAMESPACE="${NAMESPACE:-micro-onos}"

if [ ! -d "$DEVICES_DIR" ]; then
    echo "[ERROR] Directory $DEVICES_DIR not found."
    exit 1
fi

echo "=================================================================="
echo "  Registering Quantum Devices in µONOS Topology (onos-topo)"
echo "=================================================================="

# Locate the onos-cli pod
CLI_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=onos-cli -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
          kubectl get pods -n "$NAMESPACE" -l app=onos-cli -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
          kubectl get pods -n "$NAMESPACE" 2>/dev/null | grep onos-cli | awk '{print $1}' | head -n 1)

if [ -z "$CLI_POD" ]; then
    echo "[!] ERROR: Unable to locate 'onos-cli' pod in namespace '$NAMESPACE'."
    exit 1
fi

python3 - "$DEVICES_DIR" "$NAMESPACE" "$CLI_POD" << 'EOF'
import os
import sys
import glob
import subprocess

devices_dir = sys.argv[1]
namespace = sys.argv[2]
cli_pod = sys.argv[3]

yaml_files = glob.glob(os.path.join(devices_dir, "*.yaml")) + glob.glob(os.path.join(devices_dir, "*.yml"))

if not yaml_files:
    print(f"[!] No device definition files found in {devices_dir}")
    sys.exit(0)

for filepath in yaml_files:
    dev_id = None
    address = None
    dev_type = "devicesim"
    version = "1.0.x"

    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if line.startswith("id:"):
                dev_id = line.split(":", 1)[1].strip().strip('"').strip("'")
            elif line.startswith("address:"):
                address = line.split(":", 1)[1].strip().strip('"').strip("'")
            elif line.startswith("type:"):
                dev_type = line.split(":", 1)[1].strip().strip('"').strip("'")
            elif line.startswith("version:"):
                version = line.split(":", 1)[1].strip().strip('"').strip("'")

    if not dev_id or not address:
        print(f"[EXCLUDED] Skipping {filepath}: Missing 'id' or 'address'.")
        continue

    print(f"[*] Provisioning Topology Entity: '{dev_id}' -> Address: '{address}'")

    # Cleanup existing entity to ensure clean state
    subprocess.run(
        ["kubectl", "exec", "-n", namespace, cli_pod, "--", "onos", "topo", "delete", "entity", dev_id],
        capture_output=True, text=True
    )

    # Create entity with Configurable aspect
    aspect_json = f'{{"address": "{address}", "type": "{dev_type}", "version": "{version}"}}'
    cmd_create = [
        "kubectl", "exec", "-n", namespace, cli_pod, "--",
        "onos", "topo", "create", "entity", dev_id,
        "--aspect", f"onos.topo.Configurable={aspect_json}"
    ]

    result = subprocess.run(cmd_create, capture_output=True, text=True)

    if result.returncode == 0:
        print(f"    [SUCCESS] Registered '{dev_id}' in onos-topo successfully.")
    else:
        print(f"    [WARNING] Registration failed for '{dev_id}'. Output: {result.stderr.strip()}")

print("==================================================================")
EOF
