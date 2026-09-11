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

CLI_POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=onos-cli -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
          kubectl get pods -n "$NAMESPACE" -l app=onos-cli -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
          kubectl get pods -n "$NAMESPACE" 2>/dev/null | grep onos-cli | awk '{print $1}' | head -n 1)

if [ -z "$CLI_POD" ]; then
    echo "[!] ERROR: Unable to locate 'onos-cli' pod in namespace '$NAMESPACE'."
    exit 1
fi

python3 - "$DEVICES_DIR" "$NAMESPACE" "$CLI_POD" << 'PYEOF'
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
    kind = "devicesim"
    role = "quantum-switch"
    version = "1.0.x"
    gnmi_port = None
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

    if not dev_id or not address:
        print(f"[EXCLUDED] Skipping {filepath}: Missing 'id' or 'address'.")
        continue

    host_ip = address.split(":")[0] if ":" in address else address

    print(f"[*] Provisioning Topology Entity: '{dev_id}' (Kind: '{kind}') -> Primary: '{address}'")

    # 1. Delete entity if it exists to ensure clean state
    subprocess.run(
        ["kubectl", "exec", "-n", namespace, cli_pod, "--", "onos", "topo", "delete", "entity", dev_id],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )

    # 2. Re-create entity with explicit --kind
    cmd_create = [
        "kubectl", "exec", "-n", namespace, cli_pod, "--",
        "onos", "topo", "create", "entity", dev_id, "--kind", kind
    ]
    res_create = subprocess.run(cmd_create, capture_output=True, text=True)
    if res_create.returncode != 0:
        print(f"    [WARNING] Failed creating entity '{dev_id}': {res_create.stderr.strip()}")

    # 3. Construct and apply attributes
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

    target_port = gnmi_port if gnmi_port else (netconf_port if netconf_port else "8300")
    configurable_json = f'{{"address": "{host_ip}:{target_port}", "type": "{kind}", "version": "{version}"}}'
    attrs.append(f"onos.topo.Configurable={configurable_json}")

    cmd_set = [
        "kubectl", "exec", "-n", namespace, cli_pod, "--",
        "onos", "topo", "set", "entity", dev_id
    ]
    for attr in attrs:
        cmd_set.extend(["-a", attr])

    result = subprocess.run(cmd_set, capture_output=True, text=True)

    if result.returncode == 0:
        print(f"    [SUCCESS] Created entity '{dev_id}' with Kind ID '{kind}' and updated attributes in onos-topo.")
    else:
        print(f"    [WARNING] Attribute update failed for '{dev_id}'. Output: {result.stderr.strip()}")

print("==================================================================")
PYEOF
