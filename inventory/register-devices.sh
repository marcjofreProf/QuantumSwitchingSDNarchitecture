#!/usr/bin/env bash
# inventory/register-devices.sh

set -eo pipefail

DEVICES_DIR="$(dirname "$0")/devices"
NAMESPACE="${NAMESPACE:-micro-onos}"
PORT_OVERRIDE="${1:-}" # Optional first argument to override target port (e.g. 830, 50051, or 9339)

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

python3 - "$DEVICES_DIR" "$NAMESPACE" "$CLI_POD" "$PORT_OVERRIDE" << 'EOF'
import os
import sys
import glob
import subprocess

devices_dir = sys.argv[1]
namespace = sys.argv[2]
cli_pod = sys.argv[3]
port_override = sys.argv[4] if len(sys.argv) > 4 else ""

yaml_files = glob.glob(os.path.join(devices_dir, "*.yaml")) + glob.glob(os.path.join(devices_dir, "*.yml"))

if not yaml_files:
    print(f"[!] No device definition files found in {devices_dir}")
    sys.exit(0)

for filepath in yaml_files:
    dev_id = None
    address = None
    dev_type = "devicesim"
    version = "1.0.0"

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

    # Apply port override if specified via CLI argument
    if port_override:
        ip_host = address.split(":")[0]
        address = f"{ip_host}:{port_override}"

    print(f"[*] Provisioning Topology Entity: '{dev_id}' -> Address: '{address}'")

    # Set attributes on the entity using onos topo set entity
    cmd_set = [
        "kubectl", "exec", "-n", namespace, cli_pod, "--",
        "onos", "topo", "set", "entity", dev_id,
        "-a", f"address={address}",
        "-a", f"target_type={dev_type}",
        "-a", f"version={version}"
    ]

    result = subprocess.run(cmd_set, capture_output=True, text=True)

    if result.returncode == 0:
        print(f"    [SUCCESS] Updated topology attributes for '{dev_id}' in onos-topo.")
    else:
        print(f"    [WARNING] Attribute update failed for '{dev_id}'. Output: {result.stderr.strip()}")

print("==================================================================")
EOF
