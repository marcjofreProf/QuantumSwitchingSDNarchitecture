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
import json
import subprocess
import re

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
    yaml_aspects = {}

    if HAS_YAML:
        with open(filepath, 'r') as f:
            data = yaml.safe_load(f) or {}
            dev_id = data.get("id")
            address = data.get("address")
            kind = data.get("kind_id") or data.get("kind", "devicesim")
            role = data.get("role", role)
            version = str(data.get("version", version))
            yaml_aspects = data.get("aspects", {})
            
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
        with open(filepath, 'r') as f:
            content = f.read()
            m_id = re.search(r'id:\s*["\']?([^"\x27\n]+)', content)
            m_addr = re.search(r'address:\s*["\']?([^"\x27\n]+)', content)
            m_kind = re.search(r'(?:kind_id|kind):\s*["\']?([^"\x27\n]+)', content)
            m_ver = re.search(r'version:\s*["\']?([^"\x27\n]+)', content)
            m_role = re.search(r'role:\s*["\']?([^"\x27\n]+)', content)
            if m_id: dev_id = m_id.group(1).strip()
            if m_addr: address = m_addr.group(1).strip()
            if m_kind: kind = m_kind.group(1).strip()
            if m_ver: version = m_ver.group(1).strip()
            if m_role: role = m_role.group(1).strip()

    if not dev_id or not address:
        print(f"[EXCLUDED] Skipping {filepath}: Missing 'id' or 'address'.")
        continue

    host_parts = address.split(":")
    host_ip = host_parts[0]
    default_addr_port = host_parts[1] if len(host_parts) > 1 else "50051"

    # Protocol port fallbacks to guarantee all address aspects exist
    gnmi_port = gnmi_port or default_addr_port
    gnoi_port = gnoi_port or gnmi_port
    netconf_port = netconf_port or "8300"

    print(f"[*] Provisioning Topology Entity: '{dev_id}' (Kind: '{kind}') -> Primary: '{address}'")

    # 1. Delete entity if it exists to ensure clean state
    subprocess.run(
        ["kubectl", "exec", "-n", namespace, cli_pod, "--", "onos", "topo", "delete", "entity", dev_id],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )

    # 2. Re-create entity with explicit --kind
    cmd_create = [
        "kubectl", "exec", "-n", namespace, cli_pod, "--",
        "onos", "topo", "create", "entity", dev_id, "-k", kind
    ]
    res_create = subprocess.run(cmd_create, capture_output=True, text=True)
    if res_create.returncode != 0:
        print(f"    [WARNING] Failed creating entity '{dev_id}': {res_create.stderr.strip()}")

    # 3. Construct base attributes
    attrs = [
        f"address={address}",
        f"target_type={kind}",
        f"role={role}",
        f"version={version}",
        f"gnmi_address={host_ip}:{gnmi_port}",
        f"gnoi_address={host_ip}:{gnoi_port}",
        f"netconf_address={host_ip}:{netconf_port}"
    ]

    # Apply onos.topo.Configurable and TLSOptions from YAML aspects or generated fallbacks
    if "onos.topo.Configurable" in yaml_aspects:
        attrs.append(f"onos.topo.Configurable={json.dumps(yaml_aspects['onos.topo.Configurable'])}")
    else:
        attrs.append(f'onos.topo.Configurable={json.dumps({"address": f"{host_ip}:{gnmi_port}", "type": kind, "version": version})}')

    if "onos.topo.TLSOptions" in yaml_aspects:
        attrs.append(f"onos.topo.TLSOptions={json.dumps(yaml_aspects['onos.topo.TLSOptions'])}")
    else:
        attrs.append('onos.topo.TLSOptions={"insecure":true,"plain":true}')

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
