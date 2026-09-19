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

# Track device IDs for post-registration verification
declare -a REGISTERED_DEVICES=()
for f in "$DEVICES_DIR"/*.yaml "$DEVICES_DIR"/*.yml; do
    [ -f "$f" ] || continue
    dev_id=$(grep -E '^[[:space:]]*id:[[:space:]]*' "$f" | head -n1 | \
             sed -E 's/^[[:space:]]*id:[[:space:]]*["'"'"']?([^"'"'"'#]+).*/\1/' | tr -d ' ')
    if [ -n "$dev_id" ]; then
        REGISTERED_DEVICES+=("$dev_id")
    fi
done

echo "[*] Devices to register: ${REGISTERED_DEVICES[*]}"
echo

# ---------------------------------------------------------------------------
# Phase 1: Build the custom YANG model plugin for the Quantum Switching device
#
# The model plugin is what teaches onos-config how to validate Set requests
# against the BeagleBone's own schema. Without it, onos-config falls back to
# the built-in "devicesim" plugin, which only implements a small subset of
# OpenConfig paths.
#
# The plugin is built as a Docker image and later added as a sidecar to the
# onos-config deployment (see Phase 2).
# ---------------------------------------------------------------------------
echo
echo "=================================================================="
echo "  Building Quantum Switching model plugin"
echo "=================================================================="

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)/sdn-controller/northbound-interfaces/model-plugin"
YANG_SRC="$(cd "$(dirname "$0")/.." && pwd)/orchestration/yang-models/controller-quantum-switching.yang"
YANG_DST="${PLUGIN_DIR}/yang/controller-quantum-switching.yang"

if ! command -v docker >/dev/null 2>&1; then
    echo "[!] ERROR: docker not available; cannot build model plugin."
    exit 1
fi

mkdir -p "${PLUGIN_DIR}/yang"

if [ ! -f "${YANG_SRC}" ]; then
    echo "[!] ERROR: YANG model not found at ${YANG_SRC}"
    echo "    Expected repository file describing the Quantum Switching schema."
    exit 1
fi

echo "[*] Copying ${YANG_SRC} → ${YANG_DST}"
cp "${YANG_SRC}" "${YANG_DST}"

# metadata.yaml is required by the onosproject/model-compiler image.
# Derive its revision from the YANG file so the two never drift apart.
YANG_REVISION=$(grep -oE 'revision[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}' "${YANG_DST}" \
                | head -n1 | awk '{print $2}')
YANG_REVISION=${YANG_REVISION:-2026-08-29}

cat > "${PLUGIN_DIR}/metadata.yaml" <<EOF
name: controller-quantum-switching
version: 1.0.0
contactName: "SDN Architecture Team"
licenseName: "Apache-2.0"
artifactName: controller-quantum-switching
goPackage: github.com/onosproject/controller-quantum-switching
modules:
  - name: controller-quantum-switching
    organization: custom
    revision: "${YANG_REVISION}"
    file: controller-quantum-switching.yang
EOF

echo "[*] Running onosproject/model-compiler to generate Go code..."
PLUGIN_DIR_ABS=$(realpath "${PLUGIN_DIR}")
docker run --rm -v "${PLUGIN_DIR_ABS}:/config-model" \
    onosproject/model-compiler:v0.11.13

sudo chown -R "$(id -u):$(id -g)" "${PLUGIN_DIR}"

if [ ! -f "${PLUGIN_DIR}/Makefile" ]; then
    echo "[!] ERROR: model-compiler did not produce a Makefile in ${PLUGIN_DIR}."
    echo "    The YANG model likely has errors. Re-run:"
    echo "      docker run --rm -v ${PLUGIN_DIR_ABS}:/config-model onosproject/model-compiler:v0.11.13"
    exit 1
fi

# Fix the pinned libc6-compat version that no longer exists in Alpine 3.17
if [ -f "${PLUGIN_DIR}/Dockerfile" ]; then
    sed -i 's/libc6-compat=[0-9.]*-r[0-9]*/libc6-compat/g' "${PLUGIN_DIR}/Dockerfile"
fi

echo "[*] Building plugin image onosproject/controller-quantum-switching:1.0.0-... "
(
    cd "${PLUGIN_DIR}"
    make image
) || { echo "[!] ERROR: Failed to build model plugin image."; exit 1; }

PLUGIN_IMAGE="onosproject/controller-quantum-switching:1.0.0-controller-quantum-switching-1.0.0"

if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -qF "${PLUGIN_IMAGE}"; then
    echo "[!] ERROR: Expected image ${PLUGIN_IMAGE} was not produced."
    docker images | grep controller-quantum-switching || true
    exit 1
fi

# Ensure the image is present in K3s containerd. Re-importing is cheap and
# idempotent, so do it unconditionally rather than guarding on a check.
echo "[*] Importing ${PLUGIN_IMAGE} into K3s containerd..."
docker save "${PLUGIN_IMAGE}" | sudo k3s ctr images import -

# Sanity check
if ! sudo k3s ctr images ls -q | grep -qF "docker.io/${PLUGIN_IMAGE}"; then
    echo "[!] ERROR: ${PLUGIN_IMAGE} is not present in K3s containerd."
    exit 1
fi

echo "[SUCCESS] Model plugin built and imported."

# ---------------------------------------------------------------------------
# Phase 2: Attach the model plugin as a sidecar to onos-config
#
# onos-config loads model plugins as sidecar containers. Adding a new one
# requires a `helm upgrade` with a values override, followed by a rollout.
# ---------------------------------------------------------------------------
echo
echo "=================================================================="
echo "  Attaching model plugin to onos-config"
echo "=================================================================="

ONOS_HELM_DIR="$(cd "$(dirname "$0")/.." && pwd)/onos-helm-charts"
if [ ! -d "${ONOS_HELM_DIR}/onos-umbrella" ]; then
    echo "[!] ERROR: ${ONOS_HELM_DIR}/onos-umbrella not found."
    exit 1
fi

# Check whether the plugin sidecar is already configured
CURRENT_SIDECARS=$(kubectl get deploy onos-config -n "${NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null || echo "")

if echo "${CURRENT_SIDECARS}" | grep -qw "controller-quantum-switching"; then
    echo "[*] onos-config already has the controller-quantum-switching sidecar."
else
    echo "[*] Adding controller-quantum-switching to onos-config.modelPlugins..."

    # Helm REPLACES lists rather than merging them, so we must list all
    # existing plugins plus the new one. The schema comes from the chart's
    # onos-config/values.yaml (fields: name, image, port, endpoint).
    cat > /tmp/uonos-plugin-values.yaml <<EOF
onos-config:
  modelPlugins:
    - name: devicesim-1
      image: onosproject/devicesim:0.6.0-devicesim-1.0.x
      port: 5152
      endpoint: localhost
    - name: testdevice-1
      image: onosproject/testdevice-1.0.x:0.6.0-testdevice-1.0.x
      port: 5153
      endpoint: localhost
    - name: testdevice-2
      image: onosproject/testdevice-2.0.x:0.6.0-testdevice-2.0.x
      port: 5154
      endpoint: localhost
    - name: controller-quantum-switching
      image: ${PLUGIN_IMAGE}
      port: 5155
      endpoint: localhost
EOF

    (
        cd "${ONOS_HELM_DIR}"
        helm upgrade onos-umbrella ./onos-umbrella \
            -n "${NAMESPACE}" \
            -f /tmp/uonos-plugin-values.yaml
    ) || {
        echo "[!] ERROR: helm upgrade failed."
        exit 1
    }

    echo "[*] Waiting for onos-config rollout to complete..."
    kubectl rollout status deployment/onos-config -n "${NAMESPACE}" --timeout=180s || {
        echo "[!] WARNING: onos-config rollout did not complete in time."
    }

    echo "[*] Giving onos-config 15s to initialize the plugin..."
    sleep 15
fi

# Verify the sidecar exists
CURRENT_SIDECARS=$(kubectl get deploy onos-config -n "${NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null || echo "")

if ! echo "${CURRENT_SIDECARS}" | grep -qw "controller-quantum-switching"; then
    echo "[!] WARNING: controller-quantum-switching sidecar is not present on onos-config."
    echo "    The device will fall back to the devicesim model plugin."
fi

# Verify onos-config sees the plugin as Loaded. If it does not, the later
# Set requests will fail with "unknown method ValidateConfigChunked" or
# similar, so abort now rather than producing a misleading config list.
echo "[*] Checking plugin status inside onos-config..."
PLUGIN_TABLE=$(kubectl exec -n "${NAMESPACE}" \
    "$(kubectl get pods -n "${NAMESPACE}" -l app=onos -o jsonpath='{.items[0].metadata.name}')" -- \
    onos config get plugins 2>/dev/null || true)

echo "${PLUGIN_TABLE}"

if ! echo "${PLUGIN_TABLE}" | grep -qE '^controller-quantum-switching-1\.0\.0[[:space:]]+Loaded'; then
    echo "[!] ERROR: controller-quantum-switching plugin is not Loaded in onos-config."
    echo "    Subsequent Set requests will fail. Inspect onos-config logs:"
    echo "      kubectl logs -n ${NAMESPACE} deploy/onos-config -c controller-quantum-switching"
    echo "      kubectl logs -n ${NAMESPACE} deploy/onos-config -c onos-config | grep -i plugin"
    exit 1
fi

echo "[SUCCESS] controller-quantum-switching plugin is Loaded."

# ---------------------------------------------------------------------------
# Phase 1b: Register devices in onos-topo
# ---------------------------------------------------------------------------
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

active_dev_ids = set()
device_configs = []

for filepath in yaml_files:
    dev_id = None
    address = None
    kind = "devicesim"
    role = "quantum-switch"
    version = "1.0.x"
    gnmi_port = None
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

    active_dev_ids.add(dev_id)
    device_configs.append({
        'dev_id': dev_id,
        'address': address,
        'kind': kind,
        'role': role,
        'version': version,
        'gnmi_port': gnmi_port,
        'yaml_aspects': yaml_aspects
    })

# Remove stale topology entities from onos-topo
res_topo = subprocess.run(
    ["kubectl", "exec", "-n", namespace, cli_pod, "--", "onos", "topo", "get", "entities"],
    capture_output=True, text=True
)
if res_topo.returncode == 0:
    for line in res_topo.stdout.splitlines():
        parts = line.split()
        if parts:
            ent_id = parts[0]
            if ent_id not in active_dev_ids and ent_id not in ["Entity", "ID", "Entity ID"] and not ent_id.startswith("gnmi:"):
                print(f"[*] Removing stale topology entity: '{ent_id}'")
                subprocess.run(
                    ["kubectl", "exec", "-n", namespace, cli_pod, "--", "onos", "topo", "delete", "entity", ent_id],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
                )

# Provision active devices cleanly
for cfg in device_configs:
    dev_id = cfg['dev_id']
    address = cfg['address']
    kind = cfg['kind']
    version = cfg['version']
    yaml_aspects = cfg['yaml_aspects']
    
    address = cfg['address']
    kind = cfg['kind']
    version = cfg['version']
    yaml_aspects = cfg['yaml_aspects']

    print(f"[*] Provisioning Topology Entity: '{dev_id}' "
          f"(Kind: '{kind}') -> Primary: '{address}'")
    
    subprocess.run(
        ["kubectl", "exec", "-n", namespace, cli_pod, "--", "onos", "topo", "delete", "entity", dev_id],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )

    cmd_create = [
        "kubectl", "exec", "-n", namespace, cli_pod, "--",
        "onos", "topo", "create", "entity", dev_id, "-k", kind
    ]
    res_create = subprocess.run(cmd_create, capture_output=True, text=True)

    attrs = []
    
    if "onos.topo.Configurable" in yaml_aspects:
        configurable = yaml_aspects["onos.topo.Configurable"]
        
        if not isinstance(configurable, dict):
            print(f"    [WARNING] Invalid onos.topo.Configurable "
                  f"for '{dev_id}'")
            continue
        
        attrs.append(
            f"onos.topo.Configurable={json.dumps(configurable, separators=(',', ':'))}"
        )
    else:
        attrs.append(
            "onos.topo.Configurable=" +
            json.dumps({
                "address": address,
                "type": kind,
                "version": version
            }, separators=(',', ':'))
        )
    
    if "onos.topo.TLSOptions" in yaml_aspects:
        tls_options = yaml_aspects["onos.topo.TLSOptions"]

        if not isinstance(tls_options, dict):
            print(f"    [WARNING] Invalid onos.topo.TLSOptions "
                  f"for '{dev_id}'")
            continue

        attrs.append(
            f"onos.topo.TLSOptions={json.dumps(tls_options, separators=(',', ':'))}"
        )
    else:
        attrs.append(
            'onos.topo.TLSOptions={"plain":true,"insecure":true}'
        )

    cmd_set = [
        "kubectl", "exec", "-n", namespace, cli_pod, "--",
        "onos", "topo", "set", "entity", dev_id
    ]
    for attr in attrs:
        cmd_set.extend(["-a", attr])

    result = subprocess.run(cmd_set, capture_output=True, text=True)

    verify = subprocess.run(
        [
            "kubectl", "exec", "-n", namespace, cli_pod, "--",
            "onos", "topo", "get", "entity", dev_id
        ],
        capture_output=True,
        text=True
    )

    if verify.returncode == 0:
        print(f"    [SUCCESS] Verified topology entity '{dev_id}'.")
        print(verify.stdout.strip())
    else:
        print(
            f"    [WARNING] Entity '{dev_id}' was created, "
            f"but verification failed:"
        )
        print(verify.stderr.strip())

PYEOF

# ---------------------------------------------------------------------------
# Phase 3: Register devices with onos-config directly via gNMI extensions
#
# onos-config reads onos-topo ONCE at startup and does not automatically
# pick up entities added later (known limitation). Extensions 101 (version)
# and 102 (type) tell onos-config which model plugin to use for a target
# it does not know about, allowing it to store config internally without
# needing the device to be reachable.
# ---------------------------------------------------------------------------
echo
echo "=================================================================="
echo "  Registering devices with onos-config via gNMI extensions"
echo "=================================================================="

# -------------------------------------------------------------------------
# Note on cleanup: onos-config's `rollback` command is designed for
# user-driven "undo my last change" workflows, not for bulk-clearing a
# config store. Every rollback itself creates a new transaction, and the
# strict "latest change per target" rule makes out-of-order rollbacks fail.
# We do NOT attempt automatic cleanup here. To reset the store, delete
# the micro-onos namespace and re-run the bootstrap.
# -------------------------------------------------------------------------
echo "[*] Current onos-config configurations (before Set):"
kubectl exec -n "$NAMESPACE" "$CLI_POD" -- \
    onos config get configurations 2>/dev/null || true
echo

# Extract the client certs from the onos-cli pod to a temp dir on the host.
# Use `kubectl exec -- cat` instead of `kubectl cp`, because the cert files
# inside the pod may be symlinks (Secret volume mount) and `kubectl cp`
# silently skips symlinks, leaving the destination empty.
# Extract the client certs from the onos-cli pod
CERT_DIR="$(mktemp -d)"
kubectl exec -n "${NAMESPACE}" "${CLI_POD}" -- cat /etc/ssl/certs/client1.crt > "${CERT_DIR}/client1.crt"
kubectl exec -n "${NAMESPACE}" "${CLI_POD}" -- cat /etc/ssl/certs/client1.key > "${CERT_DIR}/client1.key"

# Also extract the server's CA from the onos-config pod so the Python
# client can verify the server certificate properly.
CONFIG_POD=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=onos-config -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
             kubectl get pods -n "${NAMESPACE}" -l app=onos -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "${CONFIG_POD}" ]; then
    kubectl exec -n "${NAMESPACE}" "${CONFIG_POD}" -- cat /etc/onos/certs/tls.cacrt > "${CERT_DIR}/tls.cacrt" 2>/dev/null || true
fi

# Sanity check
for f in client1.crt client1.key; do
    if [ ! -s "${CERT_DIR}/${f}" ]; then
        echo "[!] ERROR: Failed to extract ${f} from ${CLI_POD}."
        exit 1
    fi
done

if [ ! -s "${CERT_DIR}/tls.cacrt" ]; then
    echo "[!] WARNING: Could not extract server CA (tls.cacrt) from onos-config."
    echo "    Python client will fail server verification."
fi

# Sanity check: both files must be non-empty
if [ ! -s "${CERT_DIR}/client1.crt" ] || [ ! -s "${CERT_DIR}/client1.key" ]; then
    echo "[!] ERROR: Failed to extract certs from ${CLI_POD}."
    echo "    Check: kubectl exec -n ${NAMESPACE} ${CLI_POD} -- ls -l /etc/ssl/certs/"
    exit 1
fi

# Start a port-forward to onos-config in the background
kubectl port-forward -n "$NAMESPACE" svc/onos-config 5150:5150 \
    >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null; rm -rf "$CERT_DIR"' EXIT

# Wait for the port-forward to come up
for i in $(seq 1 20); do
    if nc -z localhost 5150 2>/dev/null; then
        break
    fi
    sleep 0.5
done

if ! nc -z localhost 5150 2>/dev/null; then
    echo "[!] ERROR: Could not establish port-forward to onos-config."
    exit 1
fi

echo "[*] port-forward onos-config → localhost:5150 established."

# Resolve the project venv Python (has grpc/grpc_tools installed)
VENV_PY="$(cd "$(dirname "$0")/.." && pwd)/.venv/bin/python"
if [ ! -x "$VENV_PY" ]; then
    echo "[!] ERROR: Project venv Python not found at: $VENV_PY"
    echo "    Create it with:"
    echo "      python3 -m venv .venv"
    echo "      .venv/bin/pip install grpcio grpcio-tools protobuf"
    exit 1
fi
echo "[*] Using venv Python: $VENV_PY"

# Verify the Python gNMI stubs are present (we do NOT regenerate them here;
# the bootstrap script is responsible for generating them).
PROTO_DIR="$(cd "$(dirname "$0")/.." && pwd)/proto"
GNMI_EXT_PB2="${PROTO_DIR}/github/com/openconfig/gnmi/proto/gnmi_ext/gnmi_ext_pb2.py"

if [ ! -f "${PROTO_DIR}/gnmi_pb2.py" ] || [ ! -f "${PROTO_DIR}/gnmi_pb2_grpc.py" ] || [ ! -f "${GNMI_EXT_PB2}" ]; then
    echo "[!] ERROR: Python gNMI stubs missing. Expected:"
    echo "      ${PROTO_DIR}/gnmi_pb2.py"
    echo "      ${PROTO_DIR}/gnmi_pb2_grpc.py"
    echo "      ${GNMI_EXT_PB2}"
    echo "    Regenerate with:"
    echo "      .venv/bin/python -m grpc_tools.protoc \\"
    echo "        -I${PROTO_DIR} \\"
    echo "        --python_out=${PROTO_DIR} \\"
    echo "        --grpc_python_out=${PROTO_DIR} \\"
    echo "        ${PROTO_DIR}/gnmi.proto \\"
    echo "        ${PROTO_DIR}/github.com/openconfig/gnmi/proto/gnmi_ext/gnmi_ext.proto"
    exit 1
fi

# Run the extension-based registration for each device
for cfg in "${REGISTERED_DEVICES[@]}"; do
    # Read kind and version from the YAML
    yaml_file=$(grep -l "id:\s*[\"']\?${cfg}[\"']\?" "$DEVICES_DIR"/*.yaml 2>/dev/null | head -n1)
    if [ -z "$yaml_file" ]; then
        echo "[!] Could not find YAML for device '$cfg'; skipping."
        continue
    fi

    dev_type=$(grep -E '^\s*(kind_id|kind):\s*' "$yaml_file" | head -n1 | \
               sed -E 's/^\s*(kind_id|kind):\s*["'"'"']?([^"'"'"'#]+).*/\2/' | tr -d ' ')
    dev_version=$(grep -E '^\s*version:\s*' "$yaml_file" | head -n1 | \
                  sed -E 's/^\s*version:\s*["'"'"']?([^"'"'"'#]+).*/\1/' | tr -d ' ')
    dev_type=${dev_type:-devicesim}
    dev_version=${dev_version:-1.0.x}

    echo
    echo "[*] Sending Set with extensions to onos-config for '$cfg'"
    echo "    type='$dev_type' version='$dev_version'"

    # Per-device path/value
    case "$cfg" in
        quantum-node-1)
            set_path="/switching/state"
            set_value="enabled"
            ;;
        *)
            set_path="/system/config/motd-banner"
            set_value="Registered via extensions"
            ;;
    esac

    "$VENV_PY" "$(dirname "$0")/gnmi_set_with_ext.py" \
        --address localhost:5150 \
        --target "$cfg" \
        --type "$dev_type" \
        --version "$dev_version" \
        --path "$set_path" \
        --value "$set_value" \
        --cert "${CERT_DIR}/client1.crt" \
        --key  "${CERT_DIR}/client1.key" \
        --ca   "${CERT_DIR}/tls.cacrt" \
        --server-name "onos-config.opennetworking.org" \
        || echo "    [WARNING] Set failed for '$cfg' (see above)."
done

echo
echo "[*] Verifying onos-config now knows about the targets..."
kubectl exec -n "$NAMESPACE" "$CLI_POD" -- \
    onos config get configurations || true

echo
echo "[SUCCESS] Device registration with onos-config complete."
