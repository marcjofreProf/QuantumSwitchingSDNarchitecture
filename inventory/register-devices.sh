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

try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False

yaml_files = glob.glob(os.path.join(devices_dir, "*.yaml")) + glob.glob(os.path.join(devices_dir, "*.yml"))

if not yaml_files:
    print(f"[!] No device definition files found in {devices_dir}")
    sys.exit(0)

for filepath in yaml_files:
    dev_id = None
    address = None
    kind = "beaglebone-qswitch"
    role = "quantum-switch"
    version = "1.0.0"
    gnoi_port = None
    netconf_port = None

    if HAS_YAML:
        with open(filepath, 'r') as f:
            data = yaml.safe_load(f) or {}
            dev_id = data.get("id")
            address = data.get("address")
            kind = data.get("kind", kind)
            role = data.get("role", role)
            version = str(data.get("version", version))
            
            protocols = data.get("protocols", [])
            for proto in protocols:
                if isinstance(proto, dict):
                    name = str(proto.get("name", "")).lower()
                    port = str(proto.get("port", ""))
                    if name == "gnmi":
                        gnmi_port = port
                    elif name == "gnoi":
                        gnoi_port = port
                    elif name == "netconf":
                        netconf_port = port
    else:
        # Fallback basic parser if pyyaml is missing
        with open(filepath, 'r') as f:
            lines = f.readlines()
            current_proto = None
            for line in lines:
                line = line.strip()
                if line.startswith("id:"):
                    dev_id = line.split(":", 1)[1].strip().strip('"').strip("'")
                elif line.startswith("address:"):
                    address = line.split(":", 1)[1].strip().strip('"').strip("'")
                elif line.startswith("kind:"):
                    kind = line.split(":", 1)[1].strip().strip('"').strip("'")
                elif line.startswith("role:"):
                    role = line.split(":", 1)[1].strip().strip('"').strip("'")
                elif line.startswith("- name:"):
                    current_proto = line.split(":", 1)[1].strip().strip('"').strip("'").lower()
                elif line.startswith("port:") and current_proto:
                    port_val = line.split(":", 1)[1].strip()
                    if current_proto == "gnoi":
                        gnoi_port = port_val
                    elif current_proto == "netconf":
                        netconf_port = port_val

    if not dev_id or not address:
        print(f"[EXCLUDED] Skipping {filepath}: Missing 'id' or 'address'.")
        continue

    host_ip = address.split(":")[0] if ":" in address else address

    # Construct attribute list
    attrs = [
        f"address={address}",
        f"target_type={kind}",
        f"role={role}",
        f"version={version}"
    ]

    if gnmi_port:
        attrs.append(f"gnmi_address={host_ip}:{gnmi_port}")
    if gnoi_port:
        attrs.append(f"gnoi_address={host_ip}:{gnoi_port}")
    if netconf_port:
        attrs.append(f"netconf_address={host_ip}:{netconf_port}")

    print(f"[*] Provisioning Topology Entity: '{dev_id}' -> Primary: '{address}' | NETCONF: '{host_ip}:{netconf_port}' | gNOI: '{host_ip}:{gnoi_port}'")

    cmd_set = [
        "kubectl", "exec", "-n", namespace, cli_pod, "--",
        "onos", "topo", "set", "entity", dev_id
    ]

    for attr in attrs:
        cmd_set.extend(["-a", attr])

    result = subprocess.run(cmd_set, capture_output=True, text=True)

    if result.returncode == 0:
        print(f"    [SUCCESS] Updated topology attributes for '{dev_id}' in onos-topo.")
    else:
        print(f"    [WARNING] Attribute update failed for '{dev_id}'. Output: {result.stderr.strip()}")

print("==================================================================")
EOF
