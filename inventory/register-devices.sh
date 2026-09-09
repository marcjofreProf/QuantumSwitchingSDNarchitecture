#!/usr/bin/env bash
# inventory/register-devices.sh

set -eo pipefail

DEVICES_DIR="$(dirname "$0")/devices"
CONTROLLER_HOST="${CONTROLLER_HOST:-localhost}"
ONOS_TOPO_ENDPOINT="${CONTROLLER_HOST}:30150"

if [ ! -d "$DEVICES_DIR" ]; then
    echo "[ERROR] Directory $DEVICES_DIR not found."
    exit 1
fi

echo "=================================================================="
echo "  Registering Quantum Devices in µONOS Topology (onos-topo)"
echo "=================================================================="

python3 - "$DEVICES_DIR" "$ONOS_TOPO_ENDPOINT" << 'EOF'
import os
import sys
import glob
import subprocess

devices_dir = sys.argv[1]
topo_endpoint = sys.argv[2]

yaml_files = glob.glob(os.path.join(devices_dir, "*.yaml")) + glob.glob(os.path.join(devices_dir, "*.yml"))

if not yaml_files:
print(f"[!] No device definition files found in {devices_dir}")
sys.exit(0)

for filepath in yaml_files:
dev_id = None
address = None

with open(filepath, 'r') as f:
    for line in f:
        line = line.strip()
        if line.startswith("id:"):
            dev_id = line.split(":", 1)[1].strip().strip('"').strip("'")
        elif line.startswith("address:"):
            address = line.split(":", 1)[1].strip().strip('"').strip("'")

if not dev_id or not address:
    print(f"[EXCLUDED] Skipping {filepath}: Missing 'id' or 'address'.")
    continue

print(f"[*] Registering Target: '{dev_id}' -> Address: '{address}'")

cmd = [
    "gnmic", "-a", topo_endpoint,
    "--tls",
    "--skip-verify",
    "--target", dev_id,
    "set",
    "--update", f"/interfaces/interface[name=eth0]/config/name:::string:::{address}"
]

result = subprocess.run(cmd, capture_output=True, text=True)
if result.returncode == 0:
    print(f"    [SUCCESS] Registered '{dev_id}' successfully.")
else:
    print(f"    [WARNING] Registration failed for '{dev_id}'. Output: {result.stderr.strip()}")

print("==================================================================")
EOF
