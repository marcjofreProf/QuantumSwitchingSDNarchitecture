# QuantumSwitchingSDNarchitecture
Project to develop the quantum network infrastructure for SDN switching

This project works in tandem with the data plane repository: [QuantumNodeSwitchingSDNoperation](https://github.com/marcjofreProf/QuantumNodeSwitchingSDNoperation.git), which houses the nodes deployments for switching; and the operations and service repository: [QuantumServiceOperationSDNarchitecture](https://github.com/marcjofreProf/QuantumServiceOperationSDNarchitecture.git), which supports operations and services for users.

```text
quantum-sdn-architecture/
├── .github/workflows/          # CI/CD pipelines (linting, container builds)
├── deploy/                     # Infrastructure as Code (IaC) for 6G-OpenLab
│   ├── k8s-cluster/            # Kubernetes bootstrapping scripts/manifests
│   └── vm-provisioning/        # Terraform/Ansible for the µONOS VM
├── docs/                       # Architecture schematics, PDFs, and API references
├── hardware-agents/            # Device-level execution and translation
│   ├── gnoi-targets/           # Lightweight gNOI server stubs for physical switches
│   ├── netconf-servers/        # NETCONF server stubs for standardized switch management
│   └── switch-drivers/         # Vendor API scripts
├── inventory/                  # Quantum device target declarations & auto-registration
│   ├── devices/                # YAML definition files for simulators and switches
│   └── register-devices.sh     # Registration runner targeting onos-topo
├── orchestration/              # Open Source MANO (OSM) integration
│   ├── osm-packages/           # Network Service (NS) and CNF descriptors
│   └── yang-models/            # Standardized YANG models for orchestration
├── sdn-controller/             # µONOS deployment and custom microservices
│   ├── apps/                   # Custom µONOS apps for optical/quantum circuit pathing
│   ├── northbound-interfaces/  # gNMI streaming telemetry and RESTCONF endpoints
│   └── southbound-plugins/     # gNOI, gRPC, and NETCONF adapter implementations
├── scripts/                    # Developer utility scripts (setup, dummy traffic)
├── tests/                      # Validation and benchmarking
│   ├── e2e-path-provisioning/  # End-to-end tests for Port A to Port B mapping
│   └── latency-benchmarks/     # Control-plane to data-plane sub-millisecond tests
├── workloads/                  # 5G/6G containerized network functions
│   └── open5gs/                # Helm charts/Kustomize files for Open5GS pods
└── bootstrap-quantum-switching-sdn.sh
└── uninstall-bootstrap-quantum-switching-sdn.sh
```

# Quantum switching SDN Architecture

An ultra-low latency, pure circuit-switched Software Defined Networking (SDN) architecture designed for quantum data planes. 

Because packet inspection cannot be performed on a single photon without destroying its quantum state, traditional header-parsing pipelines (like P4) are unusable. This architecture relies on a **microONOS (µONOS)** control plane paired with **gNOI over gRPC** and **NETCONF** to bypass heavy datastore commits and XML parsing, achieving the sub-millisecond execution speeds required for dynamic quantum path provisioning.

Designed for deployment on the **6G-OpenLab** infrastructure.

---

## Device Inventory & Topology Registration
The architecture decouples device management from the controller deployment pipeline. Network nodes (both virtual simulators and physical switches) are declared declaratively as YAML manifests in the inventory/devices/ directory.

Concept & Architecture
Declarative Definitions: Every node (devicesim-1, quantum-node-1, etc.) is defined in inventory/devices/<node-id>.yaml.

Automated Provisioning: The ./inventory/register-devices.sh script parses the YAML manifests and injects target endpoints directly into the µONOS topology service (onos-topo) via gnmic.

Adding a New Quantum Device
To onboard a new physical switch or virtual target into the control plane:

1. Create a YAML definition file inside inventory/devices/ (e.g., inventory/devices/quantum-node-2.yaml):
```text
id: "quantum-node-1"
kind_id: "controller-quantum-switching"
display_name: "Physical BeagleBone Quantum Switch 1"
address: "10.0.0.254:50051"
kind: "controller-quantum-switching"
version: "1.0.0"
role: "quantum-switch"

protocols:
  - name: "gnmi"
    port: 50051
  - name: "gnoi"
    port: 50051
  - name: "netconf"
    port: 8300

aspects:
  onos.topo.Configurable:
    address: "10.0.0.254:50051"
    type: "controller-quantum-switching"
    version: "1.0.0"

  onos.topo.TLSOptions:
    plain: true
    insecure: true
```

2. Execute the registration runner:
```bash
./inventory/register-devices.sh
```

3. Verify Registration:
Query onos-topo directly using gnmic to ensure the device is active in the controller topology:
```bash
gnmic -a localhost:30150 --skip-verify get --path /interfaces/interface
```

## Quickstart: Environment Bootstrap

To quickly set up the repository structure and install all necessary cloud-native dependencies (Docker, Kubernetes/K3s, Helm, Protoc, µONOS, Open5GS, and optionally OSM), use the provided bootstrap script.

**1. Clone the repository and navigate into it:**
```bash
git clone https://github.com/marcjofreProf/QuantumSwitchingSDNarchitecture.git
cd QuantumSwitchingSDNarchitecture
sudo chmod +x ./bootstrap-quantum-switching-sdn.sh
./bootstrap-quantum-switching-sdn.sh
```

If the centralized server lacks the RAM/CPU to run a full Kubernetes cluster and µONOS, it can bypass the SDN controller layer for testing or lightweight deployments.

## Recovery after abrupt stop:

To recover the different elements after and abrupt stop and re-start:

```bash
set -euo pipefail

NS=micro-onos
SS=onos-umbrella-consensus
DEPLOY_CFG=onos-config
DEPLOY_TOPO=onos-topo
PVCS=(
  atomix-data-onos-umbrella-consensus-0
  atomix-data-onos-umbrella-consensus-1
  atomix-data-onos-umbrella-consensus-2
)

echo "=== Pre-flight: clean any leftover consensus pods ==="
# Force-delete pods from a previous failed recovery so scale-to-0 cannot hang.
LEFTOVER=$(kubectl -n "$NS" get pods -l name="$SS" -o name 2>/dev/null || true)
if [ -n "$LEFTOVER" ]; then
    echo "$LEFTOVER" | xargs -r kubectl -n "$NS" delete --force --grace-period=0
fi

echo "=== 1. Stop consensus ==="
kubectl -n "$NS" scale statefulset "$SS" --replicas=0
for i in 0 1 2; do
    if ! kubectl -n "$NS" wait --for=delete "pod/${SS}-${i}" --timeout=120s; then
        echo "  WARN: pod/${SS}-${i} did not disappear in 120s; forcing"
        kubectl -n "$NS" delete pod/"${SS}-${i}" --force --grace-period=0 || true
    fi
done
echo "  remaining consensus pods:"
kubectl -n "$NS" get pods -l name="$SS" || echo "  (none — good)"

echo "=== 2. Patch PVC finalizers ==="
for pvc in "${PVCS[@]}"; do
    echo "  patching $pvc"
    kubectl -n "$NS" patch pvc "$pvc" \
        -p '{"metadata":{"finalizers":null}}' --type=merge
done

echo "=== 3. Delete PVCs (wipes corrupted Raft state) ==="
for pvc in "${PVCS[@]}"; do
    echo "  deleting $pvc"
    if ! kubectl -n "$NS" delete pvc "$pvc" --wait=true --timeout=60s; then
        echo "  WARN: PVC delete timed out; retrying with JSON finalizer clear"
        kubectl -n "$NS" patch pvc "$pvc" \
            --type=json -p '[{"op":"replace","path":"/metadata/finalizers","value":[]}]' || true
        kubectl -n "$NS" delete pvc "$pvc" --wait=true --timeout=60s || true
    fi
done
echo "  remaining consensus PVCs:"
if kubectl -n "$NS" get pvc 2>/dev/null | grep -q consensus; then
    echo "  ERROR: consensus PVCs still present, aborting"
    kubectl -n "$NS" get pvc | grep consensus
    exit 1
fi
echo "  (none — good)"

echo "=== 4. Bring consensus back ==="
kubectl -n "$NS" scale statefulset "$SS" --replicas=3

echo "=== 5. Wait for each replica in order ==="
for i in 0 1 2; do
    echo "  waiting for ${SS}-${i} to become Ready..."
    if ! kubectl -n "$NS" wait --for=condition=Ready "pod/${SS}-${i}" --timeout=600s; then
        echo "  ERROR: ${SS}-${i} did not become Ready in 600s"
        echo "  Recent log tail:"
        kubectl -n "$NS" logs "${SS}-${i}" --tail=30 || true
        exit 1
    fi
done

echo "=== 6. Waiting for onos-config and onos-topo to recover ==="
# Consensus being up does not mean the dependents have caught up. They may
# restart several times while re-establishing their sessions.
kubectl -n "$NS" rollout status "deploy/${DEPLOY_CFG}"  --timeout=600s
kubectl -n "$NS" rollout status "deploy/${DEPLOY_TOPO}" --timeout=300s

echo "=== 7. Sweep stale ReplicaSets (defensive) ==="
# If a prior rollout restart was interrupted, an old RS can hold a zombie
# pod alongside the new one. Scale any RS with 0 Ready to 0 replicas.
for rs in $(kubectl -n "$NS" get rs -o name 2>/dev/null); do
    ready=$(kubectl -n "$NS" get "$rs" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    desired=$(kubectl -n "$NS" get "$rs" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
    if [ "${ready:-0}" = "0" ] && [ "${desired:-0}" != "0" ]; then
        name=$(basename "$rs")
        # Skip RSes that simply haven't scaled up yet — only sweep if older than 1 min.
        age=$(kubectl -n "$NS" get "$rs" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || echo "")
        echo "  inactive RS: $name (desired=$desired ready=0 age=$age)"
    fi
done

echo
echo "=== Recovery complete ==="
kubectl -n "$NS" get pods
```
Then, re-register the devices in the micro-onos:
```bash
./inventory/register-devices.sh
```

## Hardware Debugging Tools

In the full architecture, a central SDN Controller (like µONOS) will manage the network topology and send commands to the switches automatically. 

However, during initial deployment or hardware troubleshooting, you can bypass the SDN controller and issue gRPC commands directly to individual hardware nodes using the provided developer scripts.

**Note:** Ensure you have run the bootstrap script first, as it compiles the necessary gRPC stubs from the `proto/` directory.

### Manual Node Control
Use the CLI client to test individual connections to a node using its IP address.

```bash
## Check gNOI
# Check if the hardware node is connected or disconnected
python3 ./hardware-agents/switch-drivers/gnoi-switching-client.py <NODE_IP> status

# Force the physical switch to connect (cross-connect)
python3 ./hardware-agents/switch-drivers/gnoi-switching-client.py <NODE_IP> connect

# Force the physical switch to disconnect
python3 ./hardware-agents/switch-drivers/gnoi-switching-client.py <NODE_IP> disconnect

## Check gNMI
# Check if the hardware node is connected or disconnected
python3 ./hardware-agents/switch-drivers/gnmi-switching-client.py <NODE_IP> status

# Force the physical switch to connect (cross-connect)
python3 ./hardware-agents/switch-drivers/gnmi-switching-client.py <NODE_IP> connect

# Force the physical switch to disconnect
python3 ./hardware-agents/switch-drivers/gnmi-switching-client.py <NODE_IP> disconnect

## Check NETCONF
# Check if the hardware node is connected or disconnected
python3 ./hardware-agents/switch-drivers/netconf-switching-client.py <NODE_IP> status

# Force the physical switch to connect (cross-connect)
python3 ./hardware-agents/switch-drivers/netconf-switching-client.py <NODE_IP> connect

# Force the physical switch to disconnect
python3 ./hardware-agents/switch-drivers/netconf-switching-client.py <NODE_IP> disconnect
```

## Northbound Interface Tests
These end-to-end tests verify service provisioning across the SDN controller northbound interfaces:
 - test-gnmi-northbound.sh: Validates direct gNMI/gRPC operations (Capabilities, Set, Get) against onos-config: ./tests/e2e-path-provisioning/test-gnmi-northbound.sh
 - test-restconf-northbound.py: Validates HTTP RESTCONF operations (POST, GET) against restconf-gateway: /opt/sdn-venv/bin/python3 ./tests/e2e-path-provisioning/test-restconf-northbound.py

## Environment Teardown & Cleanup

To remove installed binaries, purge the Python virtual environment and compiled stubs, delete Helm repositories, and reset the workspace to a clean Git state, run the provided teardown script:

```bash
sudo chmod +x uninstall-bootstrap-quantum-switching-sdn.sh
./uninstall-bootstrap-quantum-switching-sdn.sh
```

## Lessons-Learned
# µONOS gNMI Access

## Northbound gNMI (onos-config:5150)

The northbound API is the entry point for operators and management tools. It is served by `onos-config` and is used for `Get`, `Set`, `Subscribe`,
and `Capabilities` requests against the whole µONOS deployment.

- Protocol: gRPC over mTLS
- Client identity: `client1.crt` + `client1.key` (ONF-signed, shipped in   the `onos-cli` pod at `/etc/ssl/certs/`)
- Server-side CA: `tls.cacrt` (the CA certificate generated by `bootstrap-quantum-switching-sdn.sh`)
- Server certificate: signed by `ca.opennetworking.org`, with SANs covering `onos-config`, `onos-config.opennetworking.org`, `onos-config.micro-onos.svc`, `onos-config.micro-onos.svc.cluster.local`, `localhost`, and `127.0.0.1`
- Hostname verification: works normally. The native Python gRPC clients (`gnmi_daemon.py` used by the benchmark, and the RESTCONF gateway) verify the server against `tls.cacrt` with full chain validation.
- `gnmic --skip-verify`: required only for the `gnmic` CLI, which does not handle the current cert layout cleanly. The production code paths do not use `gnmic`.

The three files inside the `onos-config` pod (`/etc/onos/certs/tls.crt`, `tls.key`, `tls.cacrt`) form a complete, self-consistent set: the CA plus a server certificate signed by it. The two files inside the `onos-cli` pod (`/etc/ssl/certs/client1.crt`, `client1.key`) are the **client's** credential set, signed by the same CA. Don't mix them.

# Example (from an operator terminal to the controller)

    gnmic -a <onos-config-LB-IP>:5150 \
      --tls-cert /etc/onos/certs/client1.crt \
      --tls-key  /etc/onos/certs/client1.key \
      --skip-verify \
      capabilities

`--skip-verify` is a workaround for the `gnmic` CLI, not a property of the certificates. The production Python gRPC clients verify the chain against `tls.cacrt` and succeed.

## Southbound gNMI (device targets, e.g. quantum-node-1)

The southbound direction connects `onos-config` to each managed device. In this direction `onos-config` is the **client** and the device is the
**server**. The connection parameters are not stored in cert files on disk — they live in the topology entity's aspects, so `onos-config` can
read them from `onos-topo` at any time.

- Protocol: gRPC, **plaintext** (no TLS) for the current BeagleBone and the in-cluster `devicesim` simulator
- Server endpoint: whatever address is written in the `onos.topo.Configurable` aspect (e.g. `10.0.0.254:50051` for the BeagleBone, `localhost:10161` for the in-cluster simulator)
- Client credentials: **none** — these targets do not require mTLS
- CA: **none** — plaintext, so there is nothing to verify

The connection is described by two aspects on the topology entity:

    onos.topo.Configurable={"address":"<ip>:<port>","type":"<type>","version":"<ver>"}
    onos.topo.TLSOptions={"plain":true,"insecure":true}

`plain: true` tells `onos-config` to speak plaintext gRPC to that target.
`insecure: true` is redundant alongside `plain: true` but harmless, and matches what the ONF Helm charts emit by default. 

# Example (probe the BeagleBone's own gNMI server directly)

    gnmic -a 10.0.0.254:50051 \
      --insecure \
      capabilities

`gnmic --insecure` means **plaintext gRPC** — no TLS handshake at all. Do not pass `--tls-cert`, `--tls-key`, or `--tls-ca` to a plaintext
endpoint: doing so triggers a TLS handshake the server didn't ask for, and you will see "error reading server preface: EOF".

# Example (probe the same device through onos-config)

    gnmic -a <onos-config-LB-IP>:5150 \
      --tls-cert /etc/onos/certs/client1.crt \
      --tls-key  /etc/onos/certs/client1.key \
      --skip-verify \
      get \
      --path "/switching/state"

Here the northbound hop is mTLS, and `onos-config` re-emits the request southbound to the BeagleBone using the address in `onos.topo.Configurable`.

## Making `Set` operations succeed

`onos-config` validates every write against the **model plugin** registered for the target's `type` field. If the plugin does not define a
YANG path as writable, the `Set` will not be applied — regardless of how correct the transport is.

The current deployment has two distinct targets:

- **`devicesim-1`** uses the built-in `devicesim` model plugin. It exercises the µONOS control loop in memory and is useful for CI and
  regression tests. It does **not** push config to a real device.

- **`quantum-node-1`** is bound to the **custom `controller-quantum-switching` model plugin** built from the BeagleBone's YANG schema (see
  `orchestration/yang-models/controller-quantum-switching.yang`). Writes to paths the YANG model marks as `config true` (e.g.
  `/switching/state`) are validated against the custom schema and pushed to the BeagleBone at `10.0.0.254:50051` over plaintext gNMI.

The custom model plugin is built and loaded automatically by `inventory/register-devices.sh` (Phase 1 and Phase 2). No manual steps are
required.

### Custom model plugin workflow (for reference)

If you need to change the schema, the end-to-end loop is:

1. Edit `orchestration/yang-models/controller-quantum-switching.yang`.
2. Run `./inventory/register-devices.sh`.
   The script rebuilds the plugin image, imports it into K3s, and `helm upgrade`s `onos-config` with the new sidecar.
3. Verify with:
   ```
   kubectl exec -n micro-onos deploy/onos-cli -- onos config get plugins
   ```
   You should see `controller-quantum-switching-1.0.0  Loaded`.

### Writable paths

The set of writable paths depends on which model plugin is loaded:

- With **`devicesim`**, a small, fixed subset of OpenConfig paths is writable.
- With the **`controller-quantum-switching`** plugin, every leaf marked `config true` in the custom YANG model is writable through
  `onos-config`.

For more information on building a custom model plugin, see `sdn-controller/northbound-interfaces/model-plugin`.

## Extensions 101 and 102

`onos-config` reads `onos-topo` **once at startup** and does not automatically pick up entities added later. When a target is added to
`onos-topo` after that read, the first `Set` request for that target must carry two gNMI extensions:

- **101** — the target's model plugin **version** (e.g. `"1.0.0"`)
- **102** — the target's model plugin **type** (e.g. `"controller-quantum-switching"`)

With these extensions present, `onos-config` loads the corresponding model plugin on the fly and stores the configuration internally,
applying it to the device when it becomes reachable. `gnmic` does not expose `--ext` on its command line, so the helper script
`inventory/gnmi_set_with_ext.py` is used to construct the `SetRequest` with both extensions embedded. See `inventory/register-devices.sh` for
the full invocation.
